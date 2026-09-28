#!/usr/bin/env python3
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

"""Download an architecture-specific APK from APKPure."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import BinaryIO, Iterable
from urllib.parse import urljoin, urlsplit

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


API_URL = "https://api.pureapk.com/m/v3/cms/app_version"
API_HEADERS = {
    "x-cv": "3172501",
    "x-sv": "29",
    "x-gp": "1",
}
ALLOWED_ARCHITECTURES = {
    "arm64-v8a",
    "armeabi-v7a",
    "armeabi",
    "x86",
    "x86_64",
}
# APKPure's architecture-filtered index occasionally omits an older XAPK even
# though that archive contains the requested split. Exact-version discovery
# may therefore use the broad index; the staging validator still rejects an
# archive that does not actually contain x86_64.
DISCOVERY_ARCHITECTURES = "arm64-v8a,armeabi-v7a,armeabi,x86,x86_64"
MAX_METADATA_BYTES = 4 * 1024 * 1024
MAX_DOWNLOAD_BYTES = 1024 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
CONNECT_TIMEOUT_SECONDS = 10
READ_TIMEOUT_SECONDS = 60
MAX_REDIRECTS = 5
MAX_EXACT_VERSION_CANDIDATES = 4
PACKAGE_PATTERN = re.compile(r"^[A-Za-z0-9._]+$")
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9._+-]+$")
DOWNLOAD_PATTERN = re.compile(rb"(X?APKJ)..(https?://[-A-Za-z0-9@:%._+~#=?&/()]+)")
VERSION_MARKER_PATTERN = re.compile(
    rb"(?<![0-9A-Za-z.+_-])([0-9]+(?:\.[0-9A-Za-z+_-]+)+):"
)


class ProviderError(RuntimeError):
    """Raised when a provider response cannot be downloaded or validated."""


def _has_version_record(metadata: bytes, version: str) -> bool:
    marker = version.encode("ascii") + b":"
    return (
        re.search(rb"(?<![0-9A-Za-z.+_-])" + re.escape(marker), metadata)
        is not None
    )


def _session() -> requests.Session:
    retry = Retry(
        total=2,
        connect=2,
        read=2,
        status=2,
        backoff_factor=0.5,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset(("GET",)),
        respect_retry_after_header=False,
    )
    session = requests.Session()
    session.headers["User-Agent"] = "Sighter-direct-apkpure/1"
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def _read_bounded(chunks: Iterable[bytes], limit: int, description: str) -> bytes:
    body = bytearray()
    for chunk in chunks:
        if not chunk:
            continue
        if len(body) + len(chunk) > limit:
            raise ProviderError(f"{description} exceeds {limit} bytes")
        body.extend(chunk)
    return bytes(body)


def _checked_content_length(response: requests.Response, limit: int) -> None:
    value = response.headers.get("Content-Length")
    if value is None:
        return
    try:
        length = int(value)
    except ValueError as error:
        raise ProviderError("server returned an invalid Content-Length") from error
    if length < 0 or length > limit:
        raise ProviderError(f"download exceeds {limit} bytes")


def _is_allowed_download_host(hostname: str | None) -> bool:
    if not hostname:
        return False
    hostname = hostname.rstrip(".").lower()
    return (
        hostname in {"pureapk.com", "apkpure.com", "winudf.com"}
        or hostname.endswith(".pureapk.com")
        or hostname.endswith(".apkpure.com")
        or hostname.endswith(".winudf.com")
    )


def _is_allowed_metadata_host(hostname: str | None) -> bool:
    if not hostname:
        return False
    return hostname.rstrip(".").lower() == "api.pureapk.com"


def _validate_metadata_redirects(response: requests.Response) -> None:
    for hop in (*response.history, response):
        parsed = urlsplit(hop.url)
        try:
            port = parsed.port
        except ValueError as error:
            raise ProviderError("APKPure returned a malformed metadata URL") from error
        if (
            parsed.scheme != "https"
            or not _is_allowed_metadata_host(parsed.hostname)
            or parsed.username is not None
            or parsed.password is not None
            or port not in (None, 443)
        ):
            raise ProviderError("APKPure redirected metadata to an untrusted host")


def _validate_download_redirects(response: requests.Response) -> None:
    for hop in (*response.history, response):
        parsed = urlsplit(hop.url)
        if parsed.scheme != "https" or not _is_allowed_download_host(parsed.hostname):
            raise ProviderError("APKPure redirected to an untrusted download host")


def _get_with_trusted_redirects(
    session: requests.Session,
    url: str,
    metadata_request: bool,
    **request_arguments,
) -> requests.Response:
    current_url = url
    for redirect_count in range(MAX_REDIRECTS + 1):
        parsed = urlsplit(current_url)
        try:
            port = parsed.port
        except ValueError as error:
            raise ProviderError("APKPure returned a malformed redirect URL") from error
        allowed_host = (
            _is_allowed_metadata_host(parsed.hostname)
            if metadata_request
            else _is_allowed_download_host(parsed.hostname)
        )
        if (
            parsed.scheme != "https"
            or not allowed_host
            or parsed.username is not None
            or parsed.password is not None
            or port not in (None, 443)
        ):
            kind = "metadata" if metadata_request else "download"
            raise ProviderError(f"APKPure redirected {kind} to an untrusted host")
        response = session.get(
            current_url,
            allow_redirects=False,
            **request_arguments,
        )
        if response.status_code not in {301, 302, 303, 307, 308}:
            return response
        location = response.headers.get("Location")
        response.close()
        if not location:
            raise ProviderError("APKPure returned a redirect without Location")
        if redirect_count == MAX_REDIRECTS:
            raise ProviderError("APKPure returned too many redirects")
        current_url = urljoin(current_url, location)
        request_arguments.pop("params", None)
    raise ProviderError("APKPure returned too many redirects")


def _validated_download(match: re.Match[bytes]) -> tuple[str, str]:
    artifact_type = match.group(1)
    try:
        download_url = match.group(2).decode("ascii")
    except UnicodeDecodeError as error:
        raise ProviderError("APKPure returned a malformed download URL") from error
    parsed = urlsplit(download_url)
    if parsed.scheme != "https" or not _is_allowed_download_host(parsed.hostname):
        raise ProviderError("APKPure returned an untrusted download URL")
    extension = ".xapk" if artifact_type == b"XAPKJ" else ".apk"
    return download_url, extension


def _find_exact_downloads(metadata: bytes, version: str) -> list[tuple[str, str]]:
    markers = list(VERSION_MARKER_PATTERN.finditer(metadata))
    matching_records = [
        (index, marker)
        for index, marker in enumerate(markers)
        if marker.group(1).decode("ascii") == version
    ]
    if not matching_records:
        raise ProviderError(f"APKPure does not offer requested version {version}")

    candidates: list[tuple[str, str]] = []
    seen_urls: set[str] = set()
    for index, marker in matching_records:
        record_end = markers[index + 1].start() if index + 1 < len(markers) else len(metadata)
        match = DOWNLOAD_PATTERN.search(metadata, marker.end(), record_end)
        if match is None:
            continue
        candidate = _validated_download(match)
        if candidate[0] not in seen_urls:
            seen_urls.add(candidate[0])
            candidates.append(candidate)
    if not candidates:
        raise ProviderError(
            f"APKPure metadata contains no download URL for version {version}"
        )
    if len(candidates) > MAX_EXACT_VERSION_CANDIDATES:
        raise ProviderError("APKPure returned too many exact-version candidates")
    return candidates


def _find_download(metadata: bytes, version: str | None) -> tuple[str, str]:
    if version is not None:
        return _find_exact_downloads(metadata, version)[0]

    match = DOWNLOAD_PATTERN.search(metadata)
    if match is None:
        raise ProviderError("APKPure metadata contains no matching download URL")
    return _validated_download(match)


def _latest_version_identity(metadata: bytes) -> tuple[str, int]:
    marker = VERSION_MARKER_PATTERN.search(metadata)
    if marker is None:
        raise ProviderError("APKPure metadata contains no version identity")

    version_bytes = marker.group(1)
    prefix = metadata[max(0, marker.start() - 128) : marker.start()]
    identity = re.search(
        rb"\x2a(?P<code_length>[\x01-\x7f])(?P<code>[0-9]+)"
        rb"\x32(?P<name_length>[\x01-\x7f])$",
        prefix,
    )
    if identity is None:
        raise ProviderError("APKPure metadata contains no version code")

    code_bytes = identity.group("code")
    if identity.group("code_length")[0] != len(code_bytes):
        raise ProviderError("APKPure metadata contains a malformed version code")
    if identity.group("name_length")[0] != len(version_bytes):
        raise ProviderError("APKPure metadata contains a malformed version name")
    try:
        version_name = version_bytes.decode("ascii")
        version_code = int(code_bytes)
    except (UnicodeDecodeError, ValueError) as error:
        raise ProviderError("APKPure metadata contains a malformed version identity") from error
    if version_code <= 0:
        raise ProviderError("APKPure metadata contains an invalid version code")
    return version_name, version_code


def _fetch_metadata(
    session: requests.Session, package: str, architecture: str
) -> bytes:
    headers = dict(API_HEADERS)
    headers["x-abis"] = architecture
    try:
        with _get_with_trusted_redirects(
            session,
            API_URL,
            True,
            params={"hl": "en-US", "package_name": package},
            headers=headers,
            stream=True,
            timeout=(CONNECT_TIMEOUT_SECONDS, READ_TIMEOUT_SECONDS),
        ) as response:
            _validate_metadata_redirects(response)
            response.raise_for_status()
            _checked_content_length(response, MAX_METADATA_BYTES)
            return _read_bounded(
                response.iter_content(CHUNK_BYTES),
                MAX_METADATA_BYTES,
                "APKPure metadata",
            )
    except requests.RequestException as error:
        raise ProviderError(f"APKPure metadata request failed: {error}") from error


def _stream_to_file(
    response: requests.Response, destination: BinaryIO, limit: int
) -> int:
    written = 0
    for chunk in response.iter_content(CHUNK_BYTES):
        if not chunk:
            continue
        written += len(chunk)
        if written > limit:
            raise ProviderError(f"download exceeds {limit} bytes")
        destination.write(chunk)
    return written


def _download(session: requests.Session, download_url: str, destination: Path) -> None:
    temporary = destination.with_name(f".{destination.name}.part")
    try:
        with _get_with_trusted_redirects(
            session,
            download_url,
            False,
            stream=True,
            timeout=(CONNECT_TIMEOUT_SECONDS, READ_TIMEOUT_SECONDS),
        ) as response:
            response.raise_for_status()
            _validate_download_redirects(response)
            _checked_content_length(response, MAX_DOWNLOAD_BYTES)
            with temporary.open("xb") as output:
                written = _stream_to_file(response, output, MAX_DOWNLOAD_BYTES)
                output.flush()
                os.fsync(output.fileno())
        if written == 0:
            raise ProviderError("APKPure returned an empty download")
        with temporary.open("rb") as downloaded:
            if downloaded.read(4) not in {b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"}:
                raise ProviderError("download is not an APK/XAPK ZIP archive")
        os.replace(temporary, destination)
    except requests.RequestException as error:
        raise ProviderError(f"APKPure download failed: {error}") from error
    finally:
        temporary.unlink(missing_ok=True)


def download(
    package: str,
    version: str | None,
    architecture: str,
    output_directory: Path,
    session: requests.Session | None = None,
) -> Path:
    if PACKAGE_PATTERN.fullmatch(package) is None:
        raise ProviderError("invalid package name")
    if version is not None and VERSION_PATTERN.fullmatch(version) is None:
        raise ProviderError("invalid version")
    if architecture not in ALLOWED_ARCHITECTURES:
        raise ProviderError(f"unsupported Android architecture: {architecture}")

    output_directory.mkdir(parents=True, exist_ok=True)
    if any(output_directory.iterdir()):
        raise ProviderError(f"output directory must be empty: {output_directory}")

    owned_session = session is None
    http = session if session is not None else _session()
    assert http is not None
    try:
        metadata = _fetch_metadata(http, package, architecture)
        if (
            version is not None
            and not _has_version_record(metadata, version)
            and architecture != DISCOVERY_ARCHITECTURES
        ):
            metadata = _fetch_metadata(
                http,
                package,
                DISCOVERY_ARCHITECTURES,
            )
        candidates = (
            _find_exact_downloads(metadata, version)
            if version is not None
            else [_find_download(metadata, None)]
        )
        version_component = version if version is not None else "latest"
        destinations: list[Path] = []
        try:
            for index, (download_url, extension) in enumerate(candidates, start=1):
                candidate_component = (
                    f"@candidate-{index:02d}" if len(candidates) > 1 else ""
                )
                destination = output_directory / (
                    f"{package}@{version_component}@{architecture}"
                    f"{candidate_component}{extension}"
                )
                _download(http, download_url, destination)
                destinations.append(destination)
        except Exception:
            for destination in destinations:
                destination.unlink(missing_ok=True)
            raise
        return destinations[0]
    finally:
        if owned_session:
            http.close()


def check_latest(
    package: str,
    architecture: str,
    session: requests.Session | None = None,
) -> tuple[str, int]:
    if PACKAGE_PATTERN.fullmatch(package) is None:
        raise ProviderError("invalid package name")
    if architecture not in ALLOWED_ARCHITECTURES:
        raise ProviderError(f"unsupported Android architecture: {architecture}")

    owned_session = session is None
    http = session if session is not None else _session()
    assert http is not None
    try:
        metadata = _fetch_metadata(http, package, architecture)
        return _latest_version_identity(metadata)
    finally:
        if owned_session:
            http.close()


def _parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download an APK directly from APKPure"
    )
    parser.add_argument("--package", required=True)
    parser.add_argument("--version")
    parser.add_argument(
        "--arch", default="x86_64", choices=sorted(ALLOWED_ARCHITECTURES)
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--check",
        action="store_true",
        help="print latest version metadata as JSON without downloading",
    )
    arguments = parser.parse_args(argv)
    if arguments.check and arguments.output is not None:
        parser.error("--check and --output are mutually exclusive")
    if not arguments.check and arguments.output is None:
        parser.error("--output is required unless --check is used")
    return arguments


def main(argv: list[str] | None = None) -> int:
    arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        if arguments.check:
            if arguments.version is not None:
                raise ProviderError("--version cannot be used with --check")
            version_name, version_code = check_latest(
                arguments.package,
                arguments.arch,
            )
            print(
                json.dumps(
                    {
                        "latest_version_code": version_code,
                        "latest_version_name": version_name,
                    },
                    separators=(",", ":"),
                    sort_keys=True,
                )
            )
        else:
            download(
                arguments.package,
                arguments.version,
                arguments.arch,
                arguments.output,
            )
    except ProviderError as error:
        print(f"direct APKPure provider: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
