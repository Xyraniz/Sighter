#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail
umask 077

readonly DESKTOP_ID="space.bigrat.sighter.desktop"
readonly ROBLOX_SCHEME="x-scheme-handler/roblox"
readonly ROBLOX_PLAYER_SCHEME="x-scheme-handler/roblox-player"

Die() {
  printf 'sighter-url-handler: %s\n' "$*" >&2
  exit 1
}

Usage() {
  cat <<'EOF'
Usage: register_url_handler.sh MODE [OPTIONS]

Install a per-user Sighter desktop entry for Roblox links.

Modes:
  --install-only          Install the desktop entry without changing defaults.
  --set-default           Install it and explicitly select Sighter for both
                          roblox and roblox-player URL schemes.

Options:
  --executable PATH       Sighter ELF or AppImage to launch. By default the
                          script finds the matching build or installed binary.
  --desktop-file PATH     Sighter desktop template. By default the source-tree
                          or installed template beside this script is used.
  -h, --help              Show this help.

Run this command as the desktop user, never through sudo.
EOF
}

RequireValue() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" && "${value}" != --* ]] ||
    Die "${option} requires a value"
}

ResolveRegularFile() {
  local path="$1"
  local label="$2"
  [[ -f "${path}" && -r "${path}" ]] ||
    Die "${label} is not a readable regular file: ${path}"
  realpath -e -- "${path}" 2>/dev/null ||
    Die "cannot resolve ${label}: ${path}"
}

ResolveExecutable() {
  local path="$1"
  [[ -f "${path}" && -x "${path}" ]] ||
    Die "Sighter executable is not a regular executable file: ${path}"
  realpath -e -- "${path}" 2>/dev/null ||
    Die "cannot resolve Sighter executable: ${path}"
}

mode=""
sighter_executable=""
desktop_source=""
while (( $# > 0 )); do
  case "$1" in
    --install-only|--set-default)
      [[ -z "${mode}" ]] || Die "select exactly one registration mode"
      mode="$1"
      shift
      ;;
    --executable)
      RequireValue "$1" "${2:-}"
      sighter_executable="$2"
      shift 2
      ;;
    --desktop-file)
      RequireValue "$1" "${2:-}"
      desktop_source="$2"
      shift 2
      ;;
    -h|--help)
      Usage
      exit 0
      ;;
    *) Die "unknown option: $1" ;;
  esac
done

[[ -n "${mode}" ]] || Die "select --install-only or --set-default"
(( EUID != 0 )) || Die "run this command as the desktop user, not root"

script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${sighter_executable}" ]]; then
  for candidate in \
      "${script_dir}/sighter" \
      "${script_dir}/../build/sighter"; do
    if [[ -f "${candidate}" && -x "${candidate}" ]]; then
      sighter_executable="${candidate}"
      break
    fi
  done
  if [[ -z "${sighter_executable}" ]]; then
    sighter_executable="$(command -v sighter 2>/dev/null || true)"
  fi
fi
[[ -n "${sighter_executable}" ]] ||
  Die "build or install Sighter, or pass --executable PATH"
sighter_executable="$(ResolveExecutable "${sighter_executable}")"
source_tree_root="$(cd -P -- "${script_dir}/.." && pwd)"
launch_working_directory=""
if [[ "${sighter_executable}" == \
      "${source_tree_root}/build/sighter" ]]; then
  launch_working_directory="${source_tree_root}"
fi

# Exec is emitted without a shell. Keep the executable path to a
# conservative Desktop Entry token set so an unusual path cannot create an
# additional argument or field code. Users can move an AppImage to such a path
# before registering it.
if [[ ! "${sighter_executable}" =~ ^/[[:alnum:]_./+:,@=-]+$ ]]; then
  Die "Sighter executable path contains unsupported desktop-entry characters"
fi

if [[ -z "${desktop_source}" ]]; then
  for candidate in \
      "${script_dir}/../packaging/${DESKTOP_ID}" \
      "${script_dir}/../share/applications/${DESKTOP_ID}"; do
    if [[ -f "${candidate}" && -r "${candidate}" ]]; then
      desktop_source="${candidate}"
      break
    fi
  done
fi
[[ -n "${desktop_source}" ]] ||
  Die "cannot find the Sighter desktop template; pass --desktop-file PATH"
desktop_source="$(ResolveRegularFile "${desktop_source}" "desktop template")"

[[ "$(grep -Fxc '[Desktop Entry]' "${desktop_source}")" == 1 &&
   "$(grep -Fxc 'Type=Application' "${desktop_source}")" == 1 &&
   "$(grep -Fxc 'Icon=space.bigrat.sighter' "${desktop_source}")" == 1 &&
   "$(grep -Fxc 'Exec=sighter %u' "${desktop_source}")" == 1 &&
   "$(grep -Fxc 'MimeType=x-scheme-handler/roblox;x-scheme-handler/roblox-player;' \
       "${desktop_source}")" == 1 &&
   "$(grep -Fxc 'X-Sighter-Managed=true' "${desktop_source}")" == 1 &&
   "$(grep -c '^Exec=' "${desktop_source}")" == 1 ]] ||
  Die "desktop template does not match the Sighter URL-handler contract"

[[ -n "${HOME:-}" && "${HOME}" == /* ]] ||
  Die "HOME must be an absolute desktop-user path"
data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
[[ "${data_home}" == /* ]] || Die "XDG_DATA_HOME must be absolute"
applications_dir="${data_home}/applications"
mkdir -p -- "${applications_dir}"
applications_dir="$(realpath -e -- "${applications_dir}")" ||
  Die "cannot resolve the per-user applications directory"
[[ -d "${applications_dir}" && ! -L "${applications_dir}" ]] ||
  Die "per-user applications path is not a regular directory"
[[ "$(stat -c '%u' -- "${applications_dir}")" == "$(id -u)" ]] ||
  Die "per-user applications directory is not owned by the current user"

desktop_target="${applications_dir}/${DESKTOP_ID}"
if [[ -e "${desktop_target}" || -L "${desktop_target}" ]]; then
  [[ -f "${desktop_target}" && ! -L "${desktop_target}" &&
     "$(stat -c '%u' -- "${desktop_target}")" == "$(id -u)" ]] ||
    Die "refusing to replace an unsafe desktop entry: ${desktop_target}"
  grep -Fxq 'X-Sighter-Managed=true' "${desktop_target}" ||
    Die "refusing to replace an unmanaged desktop entry: ${desktop_target}"
fi

temporary="$(mktemp "${applications_dir}/.${DESKTOP_ID}.XXXXXX.desktop")"
trap 'rm -f -- "${temporary}"' EXIT
while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ "${line}" == Exec=* ]]; then
    printf 'Exec=%s %%u\n' "${sighter_executable}"
    if [[ -n "${launch_working_directory}" ]]; then
      printf 'Path=%s\n' "${launch_working_directory}"
    fi
  else
    printf '%s\n' "${line}"
  fi
done <"${desktop_source}" >"${temporary}"
chmod 0644 "${temporary}"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "${temporary}" ||
    Die "generated desktop entry failed validation"
fi
mv -f -- "${temporary}" "${desktop_target}"
trap - EXIT

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q "${applications_dir}" ||
    Die "could not refresh the per-user desktop database"
else
  printf 'sighter-url-handler: warning: update-desktop-database is unavailable\n' \
    >&2
fi

if [[ "${mode}" == --set-default ]]; then
  command -v xdg-mime >/dev/null 2>&1 ||
    Die "xdg-mime is required to select the URL handler"
  xdg-mime default "${DESKTOP_ID}" \
    "${ROBLOX_SCHEME}" "${ROBLOX_PLAYER_SCHEME}" ||
    Die "could not select Sighter as the Roblox URL handler"
  for scheme in "${ROBLOX_SCHEME}" "${ROBLOX_PLAYER_SCHEME}"; do
    selected="$(xdg-mime query default "${scheme}" 2>/dev/null || true)"
    [[ "${selected}" == "${DESKTOP_ID}" ]] ||
      Die "desktop environment did not retain Sighter for ${scheme}"
  done
  printf 'Sighter now handles roblox and roblox-player links.\n'
else
  printf 'Installed %s without changing URL-handler defaults.\n' \
    "${desktop_target}"
fi
