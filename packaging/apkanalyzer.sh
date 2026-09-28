#!/bin/sh
# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0

set -eu

program=${0##*/}
case $0 in
  /*) self=$0 ;;
  */*) self=$PWD/$0 ;;
  *) self=$(command -v "$0") || exit 127 ;;
esac
directory=${self%/*}
[ "$directory" != "$self" ] || directory=.
directory=$(CDPATH= cd -P "$directory" && pwd) || exit 1
runtime_root=$directory/..
sdk_root=$runtime_root/sdk
classpath=$sdk_root/cmdline-tools/latest/lib/apkanalyzer-classpath.jar

if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  java=$JAVA_HOME/bin/java
else
  java=$(command -v java 2>/dev/null || true)
fi
[ -n "${java:-}" ] || {
  printf '%s: Java 17 runtime is unavailable\n' "$program" >&2
  exit 127
}
[ -f "$classpath" ] || {
  printf '%s: analyzer classpath is unavailable\n' "$program" >&2
  exit 1
}

exec "$java" -Dcom.android.sdklib.toolsdir="$sdk_root/cmdline-tools/latest" \
  -classpath "$classpath" com.android.tools.apk.analyzer.ApkAnalyzerCli "$@"
