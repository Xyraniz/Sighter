#!/usr/bin/env bash
# Copyright 2026 Sighter Project Authors
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

readonly ROOT="${1:?source root is required}"
readonly CMAKE_FILE="${ROOT}/CMakeLists.txt"
readonly PKGBUILD="${ROOT}/packaging/arch/PKGBUILD"
readonly AUR_STABLE_PKGBUILD="${ROOT}/packaging/aur/sighter/PKGBUILD"
readonly AUR_STABLE_SRCINFO="${ROOT}/packaging/aur/sighter/.SRCINFO"
readonly AUR_BIN_PKGBUILD="${ROOT}/packaging/aur/sighter-bin/PKGBUILD"
readonly AUR_BIN_SRCINFO="${ROOT}/packaging/aur/sighter-bin/.SRCINFO"
readonly AUR_PKGBUILD="${ROOT}/packaging/aur/sighter-git/PKGBUILD"
readonly AUR_SRCINFO="${ROOT}/packaging/aur/sighter-git/.SRCINFO"
readonly WORKFLOW="${ROOT}/.github/workflows/packages.yml"
readonly README="${ROOT}/README.md"
readonly STUB_CMAKE="${ROOT}/stubs/CMakeLists.txt"
readonly ANDROID_STUB="${ROOT}/stubs/libandroid_stub.cc"

Fail() {
  printf 'Native packaging test failed: %s\n' "$*" >&2
  exit 1
}

bash -n "${PKGBUILD}"
bash -n "${AUR_STABLE_PKGBUILD}"
bash -n "${AUR_BIN_PKGBUILD}"
bash -n "${AUR_PKGBUILD}"

grep -Fq 'include(CPack)' "${CMAKE_FILE}" ||
  Fail 'CMake does not enable CPack'
grep -Fq 'CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON' "${CMAKE_FILE}" ||
  Fail 'DEB packages do not derive shared-library dependencies'
grep -Fq 'CPACK_RPM_PACKAGE_AUTOREQPROV ON' "${CMAKE_FILE}" ||
  Fail 'RPM packages do not derive runtime requirements'
grep -Fq 'pkgname=sighter' "${PKGBUILD}" ||
  Fail 'Arch package name is not stable'
grep -Fq "'sdl3>=3.4'" "${PKGBUILD}" ||
  Fail 'Arch package does not enforce the SDL minimum'
grep -Fq "'libplacebo'" "${PKGBUILD}" ||
  Fail 'Arch package does not declare the graphics composition dependency'
grep -Fq 'pkgname=sighter-git' "${AUR_PKGBUILD}" ||
  Fail 'AUR VCS package name is not stable'
grep -Fq 'pkgname=sighter' "${AUR_STABLE_PKGBUILD}" ||
  Fail 'AUR source package name is not stable'
grep -Fq '#tag=${pkgver}' "${AUR_STABLE_PKGBUILD}" ||
  Fail 'AUR source package does not pin its Git tag'
grep -Fq "'vulkan-headers'" "${AUR_STABLE_PKGBUILD}" ||
  Fail 'AUR source package does not use the packaged Vulkan headers'
grep -Fq 'pkgbase = sighter' "${AUR_STABLE_SRCINFO}" ||
  Fail 'AUR source package has no generated .SRCINFO metadata'
grep -Fq 'pkgname=sighter-bin' "${AUR_BIN_PKGBUILD}" ||
  Fail 'AUR binary package name is not stable'
grep -Fq 'pkgbase = sighter-bin' "${AUR_BIN_SRCINFO}" ||
  Fail 'AUR binary package has no generated .SRCINFO metadata'
grep -Fq -- \
  "'sighter::git+https://github.com/Xyraniz/Sighter.git#branch=main'" \
  "${AUR_PKGBUILD}" ||
  Fail 'AUR package does not build from the upstream Git repository'
grep -Fq "provides=('sighter')" "${AUR_PKGBUILD}" ||
  Fail 'AUR VCS package does not provide the stable package name'
grep -Fq "'vulkan-headers'" "${AUR_PKGBUILD}" ||
  Fail 'AUR VCS package does not use the packaged Vulkan headers'
for aur_pkgbuild in "${AUR_STABLE_PKGBUILD}" "${AUR_PKGBUILD}"; do
  if grep -Eq \
      'libjnivm::git\+|vulkan-headers::git\+|git submodule (init|update)' \
      "${aur_pkgbuild}"; then
    Fail "AUR package downloads build-only submodules: ${aur_pkgbuild}"
  fi
  grep -Fq -- '-DSIGHTER_ENABLE_UPSTREAM_JNIVM=OFF' "${aur_pkgbuild}" ||
    Fail "AUR package enables the unused upstream JNI test library: ${aur_pkgbuild}"
done
grep -Fq -- \
  '-DSIGHTER_DEFAULT_COMPATIBILITY_MANIFEST=/usr/share/sighter/metadata/' \
  "${AUR_PKGBUILD}" ||
  Fail 'AUR package embeds a build-tree compatibility manifest path'
grep -Fq 'pkgbase = sighter-git' "${AUR_SRCINFO}" ||
  Fail 'AUR package has no generated .SRCINFO metadata'
grep -Fq 'LINKER:--no-as-needed' "${STUB_CMAKE}" ||
  Fail 'system shims can lose their host libc dependencies'
grep -Fq 'SIGHTER_MINIZIP_HAS_STREAM_TELL' "${STUB_CMAKE}" ||
  Fail 'CMake does not detect the minizip-ng offset API'
grep -Fq 'mz_stream_tell(unzGetStream(archive))' "${ANDROID_STUB}" ||
  Fail 'Android assets do not support the minizip-ng offset API'

for expected in \
    'ubuntu:26.04' \
    'fedora:44' \
    'archlinux:base-devel' \
    'minizip-ng-compat-devel' \
    '-G DEB' \
    '-G RPM' \
    'makepkg --dir' \
    'APPIMAGE_FORMAT=anylinux' \
    'quick-sharun' \
    './scripts/install_anylinux_dependencies.sh' \
    'SIGHTER_ANYLINUX_SYSTEM_INSTALL=1' \
    '--appimage-extract-and-run sighter_updater status' \
    'Sighter-x86_64.AppImage' \
    'Sighter-aarch64.AppImage' \
    'sighter-nightly-aarch64.AppImage' \
    'ubuntu-24.04-arm' \
    'gh release upload continuous'; do
  grep -Fq -- "${expected}" "${WORKFLOW}" ||
    Fail "native package workflow is missing: ${expected}"
done
grep -Fq 'needs: [appimage, appimage-aarch64, deb, rpm, arch]' \
  "${WORKFLOW}" ||
  Fail 'continuous release does not wait for the aarch64 AppImage'

grep -Fq 'paths-ignore:' "${WORKFLOW}" ||
  Fail 'native package workflow has no path filters'
grep -Fq 'Ubuntu 26.04+' "${README}" ||
  Fail 'README has no Ubuntu source dependency guide'
grep -Fq 'Arch Linux' "${README}" ||
  Fail 'README has no Arch source dependency guide'
grep -Fq 'Fedora 44+' "${README}" ||
  Fail 'README has no Fedora source dependency guide'

printf 'Native packaging contract test passed\n'
