#!/usr/bin/env bash
# Validates that test-only SDL mouse and touch input crossed the real
# production event path and reached Roblox's exported native entrypoints.

set -euo pipefail

usage() {
  echo "usage: $0 validate /path/to/input-readiness.log" >&2
  exit 2
}

[[ "${1:-}" == "validate" && -n "${2:-}" && $# -eq 2 ]] || usage
log="$2"
[[ -f "${log}" ]] || {
  echo "input readiness log is not a regular file" >&2
  exit 2
}

ordered_markers=(
  "[input] typed production input ready: mouse=1 touch=1 keyboard=1 text=0"
  "[window] first Roblox Vulkan frame presented"
  "[input] SDL readiness pointer sequence queued"
  "[input] first mouse button reached Roblox native input"
  "[input] first touch event reached Roblox native input"
  "[main] Roblox lifecycle shutdown: Stopped"
)

previous_line=0
for marker in "${ordered_markers[@]}"; do
  marker_line="$(rg --fixed-strings --line-number "${marker}" "${log}" \
    | cut -d: -f1 \
    | awk -v previous="${previous_line}" '$1 > previous { print; exit }' \
    || true)"
  if [[ -z "${marker_line}" ]]; then
    echo "INPUT readiness order violation at marker: ${marker}" >&2
    exit 1
  fi
  previous_line="${marker_line}"
done

for forbidden in \
  "Roblox interactive input export table is incomplete" \
  "nativePassMouseButton raised a JNI exception" \
  "nativePassInput raised a JNI exception"; do
  if rg --fixed-strings --quiet "${forbidden}" "${log}"; then
    echo "INPUT readiness observed a native input failure" >&2
    exit 1
  fi
done

echo "INPUT readiness passed: SDL mouse and touch reached Roblox native input"
