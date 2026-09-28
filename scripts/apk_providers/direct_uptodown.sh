#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
PACKAGE=""
VERSION=""
OUTPUT=""
ARCHITECTURE="x86_64"
MANIFEST="${SIGHTER_BOOTSTRAP_SOURCES_PATH:-${PROJECT_ROOT}/config/roblox_bootstrap_sources.json}"

while (( $# > 0 )); do
  case "$1" in
    --package) PACKAGE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --arch) ARCHITECTURE="$2"; shift 2 ;;
    --source) shift 2 ;;
    *) printf 'direct Uptodown provider: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ -n "${PACKAGE}" && -n "${VERSION}" && -n "${OUTPUT}" ]] || {
  printf 'direct Uptodown provider: package, version, and output are required\n' >&2
  exit 1
}

exec python3 "${SCRIPT_DIR}/direct_uptodown.py" \
  --package "${PACKAGE}" --version "${VERSION}" --arch "${ARCHITECTURE}" \
  --output "${OUTPUT}" \
  --bootstrap-manifest "${MANIFEST}"
