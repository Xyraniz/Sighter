#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# Apache 2.0 License
#
# scripts/add_submodules.sh — Initialises pinned upstream dependencies.
#
# Run once after the initial clone:
#   ./scripts/add_submodules.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }

info "Synchronising pinned submodule URLs…"
git submodule sync --recursive

info "Initialising libjnivm and Vulkan-Headers recursively…"
git submodule update --init --recursive

info "Verifying submodule and vendored-linker provenance…"
cmake \
  -DSIGHTER_SOURCE_DIR="${PROJECT_ROOT}" \
  -P "${PROJECT_ROOT}/tests/upstream_dependency_provenance_test.cmake"

success "Pinned upstream dependencies are ready"
