#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

# Produce a deterministic digest over every regular asset path and its bytes.
# NUL-delimited GNU coreutils output keeps unusual file names unambiguous.
PayloadAssetTreeSha256() {
  local -r assets_root="$1"
  [[ -d "${assets_root}" && ! -L "${assets_root}" ]] || return 1
  local digest
  digest="$(
    set -o pipefail
    cd -- "${assets_root}"
    find -P . -type f -printf '%P\0' |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' relative_path; do
        sha256sum --zero -- "${relative_path}"
      done |
      sha256sum | awk '{print $1}'
  )" || return 1
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "${digest}"
}
