#!/usr/bin/env python3
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

"""Download a pinned Uptodown XAPK for Sighter's first-run setup."""

from __future__ import annotations

import argparse
import errno
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
from typing import BinaryIO, Iterable
from urllib.parse import urljoin, urlsplit

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


MAX_MANIFEST_BYTES = 1024 * 1024
MAX_PAGE_BYTES = 2 * 1024 * 1024
MAX_DOWNLOAD_BYTES = 1024 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
PROGRESS_STEP_BYTES = 64 * 1024 * 1024
CONNECT_TIMEOUT_SECONDS = 10
READ_TIMEOUT_SECONDS = 60
MAX_REDIRECTS = 5
PACKAGE_PATTERN = re.compile(r"^[A-Za-z0-9._]+$")
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9._+-]+$")
FILE_ID_PATTERN = re.compile(r"^[1-9][0-9]{0,19}$")
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_=-]+(?:/[A-Za-z0-9_=-]+)*/?$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
DOWNLOAD_ORIGIN = "https://dw.uptodown.com/dwn/"


class ProviderError(RuntimeError):
    """Raised when a provider response cannot be downloaded or validated."""


class DownloadPageParser(HTMLParser):
    def __init__(self, file_id: str):
        super().__init__(convert_charrefs=True)
        self.file_id = file_id
        self.download_token: str | None = None
        self.text: list[str] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        if tag != "button":
            return
        attributes = dict(attrs)
        if attributes.get("id") != "detail-download-button":
            return
        if attributes.get("data-download-version") != self.file_id:
            raise ProviderError("Uptodown download page returned a different file ID")
        token = attributes.get("data-url")
        if token is None or TOKEN_PATTERN.fullmatch(token) is None or len(token) > 4096:
            raise ProviderError("Uptodown download page returned an invalid token")
        if self.download_token is not None:
            raise ProviderError("Uptodown download page contains duplicate tokens")
        self.download_token = token

    def handle_data(self, data: str) -> None:
        stripped = data.strip()
        if stripped:
            self.text.append(stripped)


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
    session.headers["User-Agent"] = "Sighter-direct-uptodown/1"
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


def _url_is_trusted(url: str, page_host: str | None) -> bool:
    parsed = urlsplit(url)
    try:
        port = parsed.port
    except ValueError:
        return False
    if (
        parsed.scheme != "https"
        or parsed.username is not None
        or parsed.password is not None
        or port not in (None, 443)
    ):
        return False
    host = (parsed.hostname or "").rstrip(".").lower()
    if page_host is not None:
        return host == page_host
    return host in {"dw.uptodown.com", "dw.uptodown.net"}


def _get_with_trusted_redirects(
    session: requests.Session,
    url: str,
    page_host: str | None,
    **request_arguments,
) -> requests.Response:
    current_url = url
    for redirect_count in range(MAX_REDIRECTS + 1):
        if not _url_is_trusted(current_url, page_host):
            raise ProviderError("Uptodown redirected to an untrusted host")
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
            raise ProviderError("Uptodown returned a redirect without Location")
        if redirect_count == MAX_REDIRECTS:
            raise ProviderError("Uptodown returned too many redirects")
        current_url = urljoin(current_url, location)
    raise ProviderError("Uptodown returned too many redirects")


def _load_source(
    manifest_path: Path, package: str, version: str
) -> dict[str, object]:
    try:
        descriptor = os.open(
            manifest_path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise ProviderError(
                "bootstrap source manifest must be a small regular file"
            ) from error
        raise ProviderError("bootstrap source manifest is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size > MAX_MANIFEST_BYTES
        ):
            raise ProviderError(
                "bootstrap source manifest must be a small regular file"
            )
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            encoded_document = stream.read(MAX_MANIFEST_BYTES + 1)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if len(encoded_document) > MAX_MANIFEST_BYTES:
        raise ProviderError("bootstrap source manifest exceeds its size limit")
    try:
        document = json.loads(encoded_document.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ProviderError("cannot parse bootstrap source manifest") from error
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ProviderError("unsupported bootstrap source manifest")
    sources = document.get("sources")
    if not isinstance(sources, list):
        raise ProviderError("bootstrap source manifest has no sources")
    matches = [
        source
        for source in sources
        if isinstance(source, dict)
        and source.get("package") == package
        and source.get("version_name") == version
        and source.get("provider") == "uptodown"
    ]
    if len(matches) != 1:
        raise ProviderError("no unique pinned Uptodown bootstrap source is available")
    source = matches[0]
    required = {
        "package",
        "version_name",
        "version_code",
        "abi",
        "provider",
        "page_url",
        "file_id",
        "archive_size",
        "archive_sha256",
    }
    if set(source) != required:
        raise ProviderError("pinned Uptodown bootstrap source has invalid fields")
    file_id = source["file_id"]
    page_url = source["page_url"]
    expected_size = source["archive_size"]
    expected_hash = source["archive_sha256"]
    if (
        type(source["version_code"]) is not int
        or source["version_code"] <= 0
        or source["abi"] != "x86_64"
        or not isinstance(file_id, str)
        or FILE_ID_PATTERN.fullmatch(file_id) is None
        or not isinstance(page_url, str)
        or type(expected_size) is not int
        or expected_size <= 0
        or expected_size > MAX_DOWNLOAD_BYTES
        or not isinstance(expected_hash, str)
        or SHA256_PATTERN.fullmatch(expected_hash) is None
    ):
        raise ProviderError("pinned Uptodown bootstrap source is invalid")
    parsed_page = urlsplit(page_url)
    expected_path = f"/android/download/{file_id}-x"
    if (
        not _url_is_trusted(page_url, "roblox.en.uptodown.com")
        or parsed_page.path != expected_path
        or parsed_page.query
        or parsed_page.fragment
    ):
        raise ProviderError("pinned Uptodown page URL is invalid")
    return source


def _download_page(
    session: requests.Session, source: dict[str, object]
) -> str:
    page_url = str(source["page_url"])
    try:
        with _get_with_trusted_redirects(
            session,
            page_url,
            "roblox.en.uptodown.com",
            stream=True,
            timeout=(CONNECT_TIMEOUT_SECONDS, READ_TIMEOUT_SECONDS),
        ) as response:
            response.raise_for_status()
            page = _read_bounded(
                response.iter_content(CHUNK_BYTES),
                MAX_PAGE_BYTES,
                "Uptodown download page",
            )
    except requests.RequestException as error:
        raise ProviderError(f"Uptodown page request failed: {error}") from error
    try:
        decoded = page.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ProviderError("Uptodown download page is not UTF-8") from error
    parser = DownloadPageParser(str(source["file_id"]))
    try:
        parser.feed(decoded)
        parser.close()
    except ProviderError:
        raise
    except Exception as error:
        raise ProviderError("cannot parse Uptodown download page") from error
    visible_text = " ".join(parser.text)
    for expected in (
        str(source["package"]),
        str(source["version_name"]),
        str(source["archive_sha256"]),
        "x86_64",
    ):
        if expected not in visible_text:
            raise ProviderError("Uptodown page does not match pinned metadata")
    if parser.download_token is None:
        raise ProviderError("Uptodown page contains no direct download token")
    return parser.download_token


def _stream_archive(
    response: requests.Response,
    destination: BinaryIO,
    expected_size: int,
) -> str:
    declared_size = response.headers.get("Content-Length")
    if declared_size is not None:
        try:
            parsed_size = int(declared_size)
        except ValueError as error:
            raise ProviderError("Uptodown returned an invalid Content-Length") from error
        if parsed_size != expected_size:
            raise ProviderError("Uptodown archive size differs from pinned metadata")
    digest = hashlib.sha256()
    written = 0
    next_progress = PROGRESS_STEP_BYTES
    for chunk in response.iter_content(CHUNK_BYTES):
        if not chunk:
            continue
        written += len(chunk)
        if written > expected_size:
            raise ProviderError("Uptodown archive exceeds its pinned size")
        destination.write(chunk)
        digest.update(chunk)
        if written >= next_progress:
            percent = min(100, written * 100 // expected_size)
            print(
                f"[uptodown] downloaded {written // (1024 * 1024)} MiB "
                f"({percent}%)",
                file=sys.stderr,
            )
            next_progress += PROGRESS_STEP_BYTES
    if written != expected_size:
        raise ProviderError("Uptodown archive is truncated")
    return digest.hexdigest()


def _download_archive(
    session: requests.Session,
    token: str,
    source: dict[str, object],
    destination: Path,
) -> None:
    temporary = destination.with_name(f".{destination.name}.part")
    try:
        with _get_with_trusted_redirects(
            session,
            DOWNLOAD_ORIGIN + token,
            None,
            stream=True,
            timeout=(CONNECT_TIMEOUT_SECONDS, READ_TIMEOUT_SECONDS),
            headers={"Referer": str(source["page_url"])},
        ) as response:
            response.raise_for_status()
            with temporary.open("xb") as output:
                digest = _stream_archive(
                    response,
                    output,
                    int(source["archive_size"]),
                )
                output.flush()
                os.fsync(output.fileno())
        if digest != source["archive_sha256"]:
            raise ProviderError("Uptodown archive SHA-256 differs from pinned metadata")
        with temporary.open("rb") as archive:
            if archive.read(4) not in {b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08"}:
                raise ProviderError("Uptodown response is not an XAPK ZIP archive")
        os.replace(temporary, destination)
    except requests.RequestException as error:
        raise ProviderError(f"Uptodown download failed: {error}") from error
    finally:
        temporary.unlink(missing_ok=True)


def download(
    package: str,
    version: str,
    architecture: str,
    output_directory: Path,
    manifest_path: Path,
    session: requests.Session | None = None,
) -> Path:
    if PACKAGE_PATTERN.fullmatch(package) is None:
        raise ProviderError("invalid package name")
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ProviderError("invalid version")
    if architecture != "x86_64":
        raise ProviderError("pinned Uptodown bootstrap supports only x86_64")
    output_directory.mkdir(parents=True, exist_ok=True)
    if any(output_directory.iterdir()):
        raise ProviderError(f"output directory must be empty: {output_directory}")
    source = _load_source(manifest_path, package, version)
    required_free_space = int(source["archive_size"]) * 2
    if shutil.disk_usage(output_directory).free < required_free_space:
        raise ProviderError(
            "at least "
            f"{required_free_space // (1024 * 1024)} MiB of temporary space "
            "is required"
        )
    owned_session = session is None
    http = session if session is not None else _session()
    assert http is not None
    try:
        token = _download_page(http, source)
        print(
            "[uptodown] downloading pinned x86_64 bootstrap archive "
            f"({int(source['archive_size']) // (1024 * 1024)} MiB)",
            file=sys.stderr,
        )
        destination = output_directory / f"{package}@{version}@x86_64.xapk"
        _download_archive(http, token, source, destination)
        return destination
    finally:
        if owned_session:
            http.close()


def _parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download a pinned Uptodown x86_64 bootstrap XAPK"
    )
    parser.add_argument("--package", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", required=True, choices=("x86_64",))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--bootstrap-manifest", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        download(
            arguments.package,
            arguments.version,
            arguments.arch,
            arguments.output,
            arguments.bootstrap_manifest,
        )
    except (ProviderError, OSError) as error:
        print(f"direct Uptodown provider: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
