#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "validate" || -z "${2:-}" ]]; then
  echo "usage: $0 validate LOG" >&2
  exit 2
fi

log="$2"
if [[ ! -f "${log}" ]]; then
  echo "resize readiness log does not exist" >&2
  exit 2
fi

if rg --fixed-strings --quiet \
    "[window] first Roblox Vulkan frame presented" "${log}"; then
  first_present_marker="[window] first Roblox Vulkan frame presented"
elif rg --fixed-strings --quiet \
    "[window] first Roblox frame presented" "${log}"; then
  first_present_marker="[window] first Roblox frame presented"
else
  echo "resize readiness has no real host present" >&2
  exit 1
fi

ordered_markers=(
  "${first_present_marker}"
  "[resize] SDL compositor resize requested after present="
  "[resize] typed JNI surface commit generation="
  "[resize] post-rebind host present backend="
  "[main] Roblox lifecycle shutdown: Stopped"
  "[resize] readiness completed: Stopped"
)

previous_line=0
for marker in "${ordered_markers[@]}"; do
  marker_line="$(rg --fixed-strings --line-number "${marker}" "${log}" \
    | cut -d: -f1 \
    | awk -v previous="${previous_line}" '$1 > previous { print; exit }' \
    || true)"
  if [[ -z "${marker_line}" ]]; then
    echo "resize readiness order violation at marker: ${marker}" >&2
    exit 1
  fi
  previous_line="${marker_line}"
done

if rg --fixed-strings --quiet \
    "resize recreated the surface instead of preserving its generation" \
    "${log}"; then
  echo "resize readiness recreated the native surface" >&2
  exit 1
fi

if rg --quiet '\[FATAL\]|SDL_SetWindowSize failed|resize readiness failed' \
    "${log}"; then
  echo "resize readiness log contains a terminal failure" >&2
  exit 1
fi

echo "resize readiness: real compositor/JNI rebind verified"
