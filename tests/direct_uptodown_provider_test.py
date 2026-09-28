#!/usr/bin/env python3
# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts/apk_providers/direct_uptodown.py"
SPEC = importlib.util.spec_from_file_location("direct_uptodown", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
direct_uptodown = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(direct_uptodown)


class FakeResponse:
    def __init__(self, body=b"", status_code=200, headers=None):
        self.body = body
        self.status_code = status_code
        self.headers = {} if headers is None else headers

    def __enter__(self):
        return self

    def __exit__(self, _type, _value, _traceback):
        return False

    def close(self):
        return None

    def raise_for_status(self):
        if self.status_code >= 400:
            raise direct_uptodown.requests.HTTPError(str(self.status_code))

    def iter_content(self, _chunk_size):
        midpoint = len(self.body) // 2
        yield self.body[:midpoint]
        yield self.body[midpoint:]


class FakeSession:
    def __init__(
        self,
        page: bytes,
        archive: bytes,
        redirect_host="dw.uptodown.net",
        declared_size: str | None = None,
    ):
        self.page = page
        self.archive = archive
        self.redirect_host = redirect_host
        self.declared_size = declared_size
        self.calls = []

    def close(self):
        return None

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if url.startswith("https://roblox.en.uptodown.com/"):
            return FakeResponse(self.page)
        if url.startswith("https://dw.uptodown.com/"):
            return FakeResponse(
                status_code=302,
                headers={
                    "Location": f"https://{self.redirect_host}/dwn/archive.xapk"
                },
            )
        return FakeResponse(
            self.archive,
            headers={
                "Content-Length": (
                    self.declared_size
                    if self.declared_size is not None
                    else str(len(self.archive))
                )
            },
        )


def write_manifest(root: Path, archive: bytes, digest: str | None = None) -> Path:
    manifest = root / "bootstrap.json"
    manifest.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "sources": [
                    {
                        "package": "com.roblox.client",
                        "version_name": "2.725.1142",
                        "version_code": 2546,
                        "abi": "x86_64",
                        "provider": "uptodown",
                        "page_url": (
                            "https://roblox.en.uptodown.com/android/download/"
                            "1181025994-x"
                        ),
                        "file_id": "1181025994",
                        "archive_size": len(archive),
                        "archive_sha256": digest or hashlib.sha256(archive).hexdigest(),
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    return manifest


def download_page(digest: str, include_x86=True) -> bytes:
    architecture = "arm64-v8a, x86_64" if include_x86 else "arm64-v8a"
    return f"""<!doctype html>
<html><body>
<div>com.roblox.client 2.725.1142 {architecture} {digest}</div>
<button id="detail-download-button" data-download-version="1181025994"
 data-url="trusted-token/value=/">Download</button>
</body></html>""".encode()


class DirectUptodownProviderTest(unittest.TestCase):
    def test_downloads_pinned_archive_atomically_across_allowed_redirect(self):
        archive = b"PK\x03\x04pinned-xapk"
        digest = hashlib.sha256(archive).hexdigest()
        session = FakeSession(download_page(digest), archive)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = write_manifest(root, archive)
            output = root / "output"
            destination = direct_uptodown.download(
                "com.roblox.client",
                "2.725.1142",
                "x86_64",
                output,
                manifest,
                session,
            )
            self.assertEqual(destination.read_bytes(), archive)
            self.assertFalse(any(output.glob("*.part")))
        self.assertEqual(len(session.calls), 3)
        self.assertEqual(
            session.calls[1][0],
            "https://dw.uptodown.com/dwn/trusted-token/value=/",
        )

    def test_rejects_untrusted_download_redirect_without_partial_file(self):
        archive = b"PK\x03\x04pinned-xapk"
        digest = hashlib.sha256(archive).hexdigest()
        session = FakeSession(download_page(digest), archive, "attacker.example")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = write_manifest(root, archive)
            output = root / "output"
            with self.assertRaisesRegex(
                direct_uptodown.ProviderError, "untrusted host"
            ):
                direct_uptodown.download(
                    "com.roblox.client",
                    "2.725.1142",
                    "x86_64",
                    output,
                    manifest,
                    session,
                )
            self.assertEqual(list(output.iterdir()), [])
        self.assertEqual(len(session.calls), 2)

    def test_rejects_page_without_pinned_x86_metadata(self):
        archive = b"PK\x03\x04pinned-xapk"
        digest = hashlib.sha256(archive).hexdigest()
        session = FakeSession(download_page(digest, include_x86=False), archive)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = write_manifest(root, archive)
            with self.assertRaisesRegex(
                direct_uptodown.ProviderError, "does not match pinned metadata"
            ):
                direct_uptodown.download(
                    "com.roblox.client",
                    "2.725.1142",
                    "x86_64",
                    root / "output",
                    manifest,
                    session,
                )
        self.assertEqual(len(session.calls), 1)

    def test_rejects_hash_mismatch_and_removes_partial_file(self):
        archive = b"PK\x03\x04pinned-xapk"
        pinned_digest = "0" * 64
        session = FakeSession(download_page(pinned_digest), archive)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = write_manifest(root, archive, pinned_digest)
            output = root / "output"
            with self.assertRaisesRegex(
                direct_uptodown.ProviderError, "SHA-256 differs"
            ):
                direct_uptodown.download(
                    "com.roblox.client",
                    "2.725.1142",
                    "x86_64",
                    output,
                    manifest,
                    session,
                )
            self.assertEqual(list(output.iterdir()), [])

    def test_rejects_mismatched_content_length_and_non_zip_archive(self):
        archive = b"PK\x03\x04pinned-xapk"
        digest = hashlib.sha256(archive).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = write_manifest(root, archive)
            wrong_size = FakeSession(
                download_page(digest),
                archive,
                declared_size=str(len(archive) + 1),
            )
            output = root / "wrong-size"
            with self.assertRaisesRegex(
                direct_uptodown.ProviderError, "size differs"
            ):
                direct_uptodown.download(
                    "com.roblox.client",
                    "2.725.1142",
                    "x86_64",
                    output,
                    manifest,
                    wrong_size,
                )
            self.assertEqual(list(output.iterdir()), [])

            non_zip = b"not-a-zip-archive"
            non_zip_digest = hashlib.sha256(non_zip).hexdigest()
            non_zip_manifest = write_manifest(
                root, non_zip, non_zip_digest
            )
            non_zip_session = FakeSession(
                download_page(non_zip_digest), non_zip
            )
            non_zip_output = root / "non-zip"
            with self.assertRaisesRegex(
                direct_uptodown.ProviderError, "not an XAPK"
            ):
                direct_uptodown.download(
                    "com.roblox.client",
                    "2.725.1142",
                    "x86_64",
                    non_zip_output,
                    non_zip_manifest,
                    non_zip_session,
                )
            self.assertEqual(list(non_zip_output.iterdir()), [])

    def test_rejects_boolean_numeric_manifest_fields(self):
        archive = b"PK\x03\x04pinned-xapk"
        digest = hashlib.sha256(archive).hexdigest()
        session = FakeSession(download_page(digest), archive)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = write_manifest(root, archive)
            document = json.loads(manifest.read_text(encoding="utf-8"))
            document["sources"][0]["archive_size"] = True
            manifest.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(
                direct_uptodown.ProviderError, "source is invalid"
            ):
                direct_uptodown.download(
                    "com.roblox.client",
                    "2.725.1142",
                    "x86_64",
                    root / "output",
                    manifest,
                    session,
                )
        self.assertEqual(len(session.calls), 0)

    def test_rejects_symlink_manifest(self):
        archive = b"PK\x03\x04pinned-xapk"
        digest = hashlib.sha256(archive).hexdigest()
        session = FakeSession(download_page(digest), archive)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = write_manifest(root, archive)
            link = root / "linked.json"
            link.symlink_to(manifest)
            with self.assertRaisesRegex(
                direct_uptodown.ProviderError, "small regular file"
            ):
                direct_uptodown.download(
                    "com.roblox.client",
                    "2.725.1142",
                    "x86_64",
                    root / "output",
                    link,
                    session,
                )
        self.assertEqual(len(session.calls), 0)


if __name__ == "__main__":
    unittest.main()
