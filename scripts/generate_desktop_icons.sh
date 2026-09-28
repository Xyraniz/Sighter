#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly source_icon="${project_root}/packaging/space.bigrat.sighter.svg"
readonly output_root="${project_root}/packaging/icons/hicolor"
readonly icon_name="space.bigrat.sighter.png"
readonly icon_sizes=(16 22 24 32 36 48 64 72 96 128 192 256 512)

if ! command -v magick >/dev/null 2>&1; then
  printf 'ImageMagick 7 (magick) is required to regenerate desktop icons\n' >&2
  exit 1
fi

for size in "${icon_sizes[@]}"; do
  destination="${output_root}/${size}x${size}/apps/${icon_name}"
  mkdir -p -- "$(dirname -- "${destination}")"
  magick -background none "${source_icon}" -alpha on -filter Lanczos \
    -resize "${size}x${size}" -depth 8 -strip "PNG32:${destination}"
done

printf 'Generated %d hicolor icons from %s\n' \
  "${#icon_sizes[@]}" "${source_icon}"
