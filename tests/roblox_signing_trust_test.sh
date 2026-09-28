#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

set -Eeuo pipefail

trust="${1:?trust manifest is required}"
payload="${2:?payload metadata is required}"
jq -e '.schema_version == 1 and .package == "com.roblox.client" and
       (.trusted_sha256 | type == "array" and length > 0) and
       all(.trusted_sha256[]; test("^[0-9a-f]{64}$"))' "${trust}" >/dev/null

comm -12 \
  <(jq -r '.signing_certificates_sha256[] | ascii_downcase' "${payload}" | sort -u) \
  <(jq -r '.trusted_sha256[] | ascii_downcase' "${trust}" | sort -u) |
  grep -Eq '^[0-9a-f]{64}$' || {
    echo "active payload has no pinned Roblox signing certificate" >&2
    exit 1
  }

echo "Roblox signing trust checks passed"
