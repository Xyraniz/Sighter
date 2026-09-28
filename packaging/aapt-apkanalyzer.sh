#!/bin/sh
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

set -eu

case $0 in
  /*) self=$0 ;;
  */*) self=$PWD/$0 ;;
  *) self=$(command -v "$0") || exit 127 ;;
esac
directory=${self%/*}
[ "$directory" != "$self" ] || directory=.
directory=$(CDPATH= cd -P "$directory" && pwd) || exit 1
analyzer=$directory/apkanalyzer

case ${1:-} in
  version)
    [ "$#" -eq 1 ] || exit 2
    printf 'Android APK badging adapter backed by apkanalyzer\n'
    ;;
  dump)
    [ "$#" -eq 3 ] && [ "$2" = badging ] || exit 2
    apk=$3
    package=$("$analyzer" manifest application-id "$apk")
    version_code=$("$analyzer" manifest version-code "$apk")
    version_name=$("$analyzer" manifest version-name "$apk")
    manifest=$("$analyzer" manifest print "$apk")
    split=$(printf '%s\n' "$manifest" |
      sed -n 's/^[[:space:]]*split="\([^"]*\)".*/\1/p' |
      sed -n '1p')
    case "$package$version_code$version_name$split" in
      *"'"*)
        printf 'aapt: APK metadata contains an unsupported quote\n' >&2
        exit 1
        ;;
    esac
    printf "package: name='%s' versionCode='%s' versionName='%s'" \
      "$package" "$version_code" "$version_name"
    [ -z "$split" ] || printf " split='%s'" "$split"
    printf '\n'
    ;;
  *)
    printf 'usage: aapt version | aapt dump badging APK\n' >&2
    exit 2
    ;;
esac
