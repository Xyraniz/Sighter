#!/usr/bin/env python3
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "scripts/apk_providers/direct_apkpure.py"
SPEC = importlib.util.spec_from_file_location("direct_apkpure", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
direct_apkpure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(direct_apkpure)


class FakeResponse:
    def __init__(self, body: bytes, url: str, headers=None, history=(), status_code=200):
        self.body = body
        self.url = url
        self.headers = {} if headers is None else headers
        self.history = tuple(history)
        self.status_code = status_code

    def __enter__(self):
        return self

    def __exit__(self, _type, _value, _traceback):
        return False

    def raise_for_status(self):
        return None

    def close(self):
        return None

    def iter_content(self, _chunk_size):
        midpoint = len(self.body) // 2
        yield self.body[:midpoint]
        yield self.body[midpoint:]


class FakeSession:
    def __init__(
        self,
        metadata: bytes,
        archive: bytes,
        final_url=None,
        headers=None,
        metadata_final_url=None,
    ):
        self.metadata = metadata
        self.archive = archive
        self.final_url = final_url or "https://data.winudf.com/roblox.apk"
        self.download_headers = headers or {}
        self.metadata_final_url = metadata_final_url or direct_apkpure.API_URL
        self.calls = []

    def close(self):
        return None

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if url == direct_apkpure.API_URL:
            history = ()
            if self.metadata_final_url != direct_apkpure.API_URL:
                history = (FakeResponse(b"", direct_apkpure.API_URL),)
            return FakeResponse(self.metadata, self.metadata_final_url, history=history)
        redirect = FakeResponse(b"", url)
        return FakeResponse(
            self.archive,
            self.final_url,
            headers=self.download_headers,
            history=(redirect,),
        )


def metadata(*records: tuple[str, str, str]) -> bytes:
    result = bytearray(b"protobuf-prefix\x00")
    for version, artifact_type, url in records:
        result.extend(version.encode("ascii"))
        result.extend(b":metadata\x00")
        result.extend(artifact_type.encode("ascii"))
        result.extend(b"\x00\x00")
        result.extend(url.encode("ascii"))
        result.extend(b"\x00")
    return bytes(result)


def api_metadata(*records: tuple[str, int, str, str, str]) -> bytes:
    result = bytearray(b"protobuf-prefix\x00")
    for version_name, version_code, artifact_type, url, suffix in records:
        code = str(version_code).encode("ascii")
        name = version_name.encode("ascii")
        result.extend(b"\x2a")
        result.append(len(code))
        result.extend(code)
        result.extend(b"\x32")
        result.append(len(name))
        result.extend(name)
        result.extend(b":")
        result.extend(suffix.encode("ascii"))
        result.extend(b"\x00")
        result.extend(artifact_type.encode("ascii"))
        result.extend(b"\x00\x00")
        result.extend(url.encode("ascii"))
        result.extend(b"\x00")
    return bytes(result)


class DirectApkPureProviderTest(unittest.TestCase):
    def test_downloads_latest_x86_64_apk_atomically(self):
        source = "https://download.pureapk.com/b/APK/latest"
        session = FakeSession(metadata(("2.2", "APKJ", source)), b"PK\x03\x04payload")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            destination = direct_apkpure.download(
                "com.roblox.client", None, "x86_64", output, session
            )
            self.assertEqual(destination.name, "com.roblox.client@latest@x86_64.apk")
            self.assertEqual(destination.read_bytes(), b"PK\x03\x04payload")
            self.assertFalse(any(output.glob("*.part")))
        metadata_call = session.calls[0][1]
        self.assertEqual(metadata_call["headers"]["x-abis"], "x86_64")
        self.assertEqual(metadata_call["params"]["package_name"], "com.roblox.client")

    def test_selects_requested_version_and_preserves_xapk(self):
        latest = "https://download.pureapk.com/b/APK/latest"
        requested = "https://download.pureapk.com/b/XAPK/requested"
        session = FakeSession(
            metadata(
                ("2.10", "APKJ", latest),
                ("2.9", "XAPKJ", requested),
            ),
            b"PK\x03\x04xapk",
        )
        with tempfile.TemporaryDirectory() as temporary:
            destination = direct_apkpure.download(
                "com.roblox.client", "2.9", "x86_64", Path(temporary), session
            )
            self.assertEqual(destination.suffix, ".xapk")
            self.assertEqual(session.calls[1][0], requested)

    def test_exact_version_falls_back_to_broad_discovery_index(self):
        latest = "https://download.pureapk.com/b/APK/latest"
        requested_a = "https://download.pureapk.com/b/XAPK/requested-a"
        requested_b = "https://download.pureapk.com/b/XAPK/requested-b"
        primary_metadata = metadata(("2.10", "APKJ", latest))
        discovery_metadata = metadata(
            ("2.9", "XAPKJ", requested_a),
            ("2.9", "XAPKJ", requested_b),
        )
        session = FakeSession(b"unused", b"PK\x03\x04xapk")
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(
                direct_apkpure,
                "_fetch_metadata",
                side_effect=[primary_metadata, discovery_metadata],
            ) as fetch_metadata:
                destination = direct_apkpure.download(
                    "com.roblox.client", "2.9", "x86_64", Path(temporary), session
                )
            self.assertEqual(destination.suffix, ".xapk")
            self.assertEqual(len(list(Path(temporary).glob("*.xapk"))), 2)
        self.assertEqual(fetch_metadata.call_count, 2)
        self.assertEqual(fetch_metadata.call_args_list[0].args[2], "x86_64")
        self.assertEqual(
            fetch_metadata.call_args_list[1].args[2],
            direct_apkpure.DISCOVERY_ARCHITECTURES,
        )
        self.assertEqual(
            [call[0] for call in session.calls],
            [requested_a, requested_b],
        )

    def test_requested_version_never_uses_neighboring_record(self):
        neighboring = "https://download.pureapk.com/b/APK/neighboring"
        broken_record = b"2.9:metadata-without-download\x00"
        neighboring_record = metadata(("2.10", "APKJ", neighboring))
        session = FakeSession(
            broken_record + neighboring_record,
            b"PK\x03\x04neighboring",
        )
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                direct_apkpure.ProviderError, "no download URL for version 2.9"
            ):
                direct_apkpure.download(
                    "com.roblox.client", "2.9", "x86_64", Path(temporary), session
                )
        self.assertEqual(len(session.calls), 1)

    def test_requested_version_selects_only_its_multi_record_url(self):
        previous = "https://download.pureapk.com/b/APK/previous"
        requested = "https://download.pureapk.com/b/APK/requested"
        following = "https://download.pureapk.com/b/APK/following"
        session = FakeSession(
            metadata(
                ("2.8", "APKJ", previous),
                ("2.9", "APKJ", requested),
                ("2.10", "APKJ", following),
            ),
            b"PK\x03\x04requested",
        )
        with tempfile.TemporaryDirectory() as temporary:
            direct_apkpure.download(
                "com.roblox.client", "2.9", "x86_64", Path(temporary), session
            )
        self.assertEqual(session.calls[1][0], requested)

    def test_rejects_untrusted_metadata_redirect(self):
        source = "https://download.pureapk.com/b/APK/latest"
        session = FakeSession(
            metadata(("2.2", "APKJ", source)),
            b"PK\x03\x04payload",
            metadata_final_url="https://attacker.example/app-version",
        )
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(
                direct_apkpure.ProviderError, "metadata to an untrusted host"
            ):
                direct_apkpure.download(
                    "com.roblox.client", None, "x86_64", Path(temporary), session
                )
        self.assertEqual(len(session.calls), 1)

    def test_rejects_redirect_target_before_requesting_it(self):
        session = mock.Mock()
        session.get.return_value = FakeResponse(
            b"",
            direct_apkpure.API_URL,
            headers={"Location": "http://127.0.0.1/internal"},
            status_code=302,
        )

        with self.assertRaisesRegex(
            direct_apkpure.ProviderError, "metadata to an untrusted host"
        ):
            direct_apkpure._get_with_trusted_redirects(
                session,
                direct_apkpure.API_URL,
                True,
                stream=True,
            )

        session.get.assert_called_once()

    def test_check_latest_returns_first_api_version_without_downloading(self):
        latest = "https://download.pureapk.com/b/APK/latest"
        older = "https://download.pureapk.com/b/APK/older"
        session = FakeSession(
            api_metadata(
                ("2.727.1199", 2628, "APKJ", latest, "latest-record"),
                ("2.726.1180", 2600, "APKJ", older, "older-record"),
            ),
            b"unused",
        )
        self.assertEqual(
            direct_apkpure.check_latest("com.roblox.client", "x86_64", session),
            ("2.727.1199", 2628),
        )
        self.assertEqual(len(session.calls), 1)

    def test_check_mode_prints_json_and_download_mode_keeps_stdout_empty(self):
        latest = "https://download.pureapk.com/b/APK/latest"
        check_session = FakeSession(
            api_metadata(
                ("2.727.1199", 2628, "APKJ", latest, "latest-record"),
            ),
            b"unused",
        )
        output = io.StringIO()
        with mock.patch.object(direct_apkpure, "_session", return_value=check_session):
            with mock.patch("sys.stdout", output):
                result = direct_apkpure.main(
                    ["--package", "com.roblox.client", "--check"]
                )
        self.assertEqual(result, 0)
        self.assertEqual(
            json.loads(output.getvalue()),
            {
                "latest_version_code": 2628,
                "latest_version_name": "2.727.1199",
            },
        )

        download_session = FakeSession(
            metadata(("2.727.1199", "APKJ", latest)), b"PK\x03\x04payload"
        )
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(
                direct_apkpure, "_session", return_value=download_session
            ):
                with mock.patch("sys.stdout", output):
                    result = direct_apkpure.main(
                        [
                            "--package",
                            "com.roblox.client",
                            "--output",
                            temporary,
                        ]
                    )
        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), "")

    def test_check_latest_rejects_inconsistent_version_lengths(self):
        source = "https://download.pureapk.com/b/APK/latest"
        malformed = api_metadata(
            ("2.727.1199", 2628, "APKJ", source, "latest-record"),
        ).replace(b"\x32\x0a2.727.1199", b"\x32\x092.727.1199", 1)
        session = FakeSession(malformed, b"unused")
        with self.assertRaisesRegex(
            direct_apkpure.ProviderError, "malformed version name"
        ):
            direct_apkpure.check_latest("com.roblox.client", "x86_64", session)

    def test_rejects_untrusted_redirect_and_removes_partial_file(self):
        source = "https://download.pureapk.com/b/APK/latest"
        session = FakeSession(
            metadata(("2.2", "APKJ", source)),
            b"PK\x03\x04payload",
            final_url="https://attacker.example/roblox.apk",
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with self.assertRaisesRegex(
                direct_apkpure.ProviderError, "untrusted download host"
            ):
                direct_apkpure.download(
                    "com.roblox.client", None, "x86_64", output, session
                )
            self.assertEqual(list(output.iterdir()), [])

    def test_enforces_streaming_size_limit_without_content_length(self):
        source = "https://download.pureapk.com/b/APK/latest"
        session = FakeSession(
            metadata(("2.2", "APKJ", source)),
            b"PK\x03\x04" + b"x" * 20,
        )
        previous_limit = direct_apkpure.MAX_DOWNLOAD_BYTES
        direct_apkpure.MAX_DOWNLOAD_BYTES = 16
        try:
            with tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                with self.assertRaisesRegex(
                    direct_apkpure.ProviderError, "download exceeds"
                ):
                    direct_apkpure.download(
                        "com.roblox.client", None, "x86_64", output, session
                    )
                self.assertEqual(list(output.iterdir()), [])
        finally:
            direct_apkpure.MAX_DOWNLOAD_BYTES = previous_limit

    def test_rejects_non_zip_response(self):
        source = "https://download.pureapk.com/b/APK/latest"
        session = FakeSession(metadata(("2.2", "APKJ", source)), b"not an apk")
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(direct_apkpure.ProviderError, "not an APK"):
                direct_apkpure.download(
                    "com.roblox.client", None, "x86_64", Path(temporary), session
                )

    def test_rejects_missing_version_and_nonempty_output(self):
        source = "https://download.pureapk.com/b/APK/latest"
        session = FakeSession(metadata(("2.2", "APKJ", source)), b"PK\x03\x04ok")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with self.assertRaisesRegex(direct_apkpure.ProviderError, "does not offer"):
                direct_apkpure.download(
                    "com.roblox.client", "2.1", "x86_64", output, session
                )
            (output / "existing").write_text("keep", encoding="utf-8")
            with self.assertRaisesRegex(direct_apkpure.ProviderError, "must be empty"):
                direct_apkpure.download(
                    "com.roblox.client", None, "x86_64", output, session
                )


if __name__ == "__main__":
    unittest.main()
