#!/bin/sh
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

set -eu

Die() {
  printf 'sighter: %s\n' "$*" >&2
  exit 1
}

case $0 in
  /*) self=$0 ;;
  */*) self=$PWD/$0 ;;
  *)
    self=$(command -v "$0") || Die "cannot resolve launcher path: $0"
    case $self in
      /*) ;;
      *) self=$PWD/$self ;;
    esac
    ;;
esac

bundle_dir=${self%/*}
[ "$bundle_dir" != "$self" ] || bundle_dir=.
bundle_dir=$(CDPATH= cd -P "$bundle_dir" && pwd) ||
  Die "cannot resolve launcher directory"

runtime_dir=$bundle_dir/sighter
launcher=$runtime_dir/scripts/portable_launcher.sh
installer=$runtime_dir/scripts/install_thin_dependencies.sh
standalone_bash=$runtime_dir/runtime/bin/bash
standalone_bin=$runtime_dir/runtime/bin

if [ -d "$standalone_bin" ]; then
  PATH=$standalone_bin:$PATH
  export PATH
fi

[ -f "$launcher" ] && [ -r "$launcher" ] ||
  Die "portable launcher is unavailable: $launcher"

if [ -x "$standalone_bash" ] && [ ! -d "$standalone_bash" ]; then
  exec "$standalone_bash" "$launcher" "$@"
  Die "cannot execute bundled Bash"
fi

if [ "${SIGHTER_SKIP_HOST_CHECK:-0}" != 1 ]; then
  [ -f "$installer" ] && [ -x "$installer" ] ||
    Die "thin dependency installer is unavailable: $installer"
  if ! "$installer" --check; then
    "$installer" --install ||
      Die "thin host dependencies were not installed"
  fi
fi

host_bash=$(command -v bash 2>/dev/null || true)
[ -n "$host_bash" ] ||
  Die "Bash is still unavailable; run '$installer --print' for manual steps"

exec "$host_bash" "$launcher" "$@"
Die "cannot execute host Bash"
