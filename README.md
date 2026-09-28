# Sighter

[![CI](https://github.com/Xyraniz/Sighter/actions/workflows/ci.yml/badge.svg)](https://github.com/Xyraniz/Sighter/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Sighter is an independent compatibility runtime for playing the Android
version of Roblox on Linux. It provides the Android ABI and JNI environment
expected by the client and connects it to Linux graphics and input through
SDL3, Vulkan, or OpenGL.

Sighter does not include or distribute the Roblox client. The client package
is downloaded on first launch and checked for a supported ABI and signature
before its native code is loaded. Sighter is not affiliated with Roblox
Corporation or VinegarHQ.

## Platform support

| Platform | Status | Notes |
| --- | --- | --- |
| Linux x86-64 | Supported | Runs the Android x86-64 Roblox client. |
| Linux AArch64 | Experimental | Builds target the Android `arm64-v8a` client; runtime validation is experimental. |
| FreeBSD | Experimental | Runs in Linuxulator with an x86-64 Linux userspace; it is not a native FreeBSD binary. |

## Downloads

See [GitHub Releases](https://github.com/Xyraniz/Sighter/releases) for
available packages. The CI workflows maintain a rolling
[continuous prerelease](https://github.com/Xyraniz/Sighter/releases/tag/continuous)
and publish packages when their build jobs complete successfully.

## Build from source

### Requirements

Build on Linux with CMake 3.20 or newer, Git, Ninja, a C++17 compiler, LLD,
pkg-config, and development packages for SDL3 3.4+, SDL3_ttf, Vulkan, EGL,
libplacebo, GTK4, libadwaita 1.6+, WebKitGTK 6.0, libcurl, OpenSSL, libelf,
libyaml, minizip, Capstone 5, utf8proc, fontconfig, libpng, zlib, and
nlohmann/json.

Example dependency commands for common distributions:

<details>
<summary>Ubuntu 26.04+</summary>

```bash
sudo apt update
sudo apt install build-essential cmake git ninja-build pkg-config lld \
  libsdl3-dev libsdl3-ttf-dev libcurl4-openssl-dev libssl-dev \
  nlohmann-json3-dev libyaml-dev libelf-dev libminizip-dev \
  libcapstone-dev libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev \
  libutf8proc-dev libfontconfig1-dev libegl-dev libvulkan-dev \
  libplacebo-dev libpng-dev zlib1g-dev
```
</details>

<details>
<summary>Arch Linux</summary>

```bash
sudo pacman -S --needed base-devel cmake git ninja pkgconf lld sdl3 sdl3_ttf \
  curl openssl nlohmann-json libyaml libelf minizip capstone gtk4 \
  libadwaita webkitgtk-6.0 libutf8proc fontconfig libglvnd \
  libplacebo vulkan-headers vulkan-icd-loader zlib
```
</details>

<details>
<summary>Fedora 44+</summary>

```bash
sudo dnf install gcc-c++ cmake git ninja-build pkgconf-pkg-config lld \
  SDL3-devel SDL3_ttf-devel libcurl-devel openssl-devel \
  nlohmann-json-devel libyaml-devel elfutils-libelf-devel minizip-ng-compat-devel \
  capstone-devel gtk4-devel libadwaita-devel webkitgtk6.0-devel \
  utf8proc-devel fontconfig-devel libglvnd-devel vulkan-headers \
  vulkan-loader-devel libplacebo-devel zlib-ng-compat-devel
```
</details>

Clone the repository with its pinned submodules, then build and launch:

```bash
git clone --recurse-submodules https://github.com/Xyraniz/Sighter.git
cd Sighter
make build
./build/sighter
```

Run the native test suite with `make test`. For FreeBSD setup and launch
instructions, see the [Linuxulator guide](packaging/freebsd/README.md).

## Configuration

Sighter reads optional Roblox FFlag overrides from
`$XDG_CONFIG_HOME/sighter/fflags.json` (usually
`~/.config/sighter/fflags.json`). For example:

```json
{
  "FFlagExample": "True",
  "DFIntExample": "120"
}
```

PC profiles use Roblox's legacy Charts page by default to avoid a blank
screen caused by `Color3` errors in the newer SDUI page. An explicit
`FFlagLuaAppChartsAppPage` override takes precedence.

## Troubleshooting

See the [FAQ](docs/FAQ.md) for configuration and log locations. When reporting
a problem, reproduce it and attach `latest.log`; remove any information you
do not want to share first.

Sighter is currently incompatible with `hardened_malloc`, which may prevent
startup or cause runtime crashes.

## License

Sighter is licensed under the [Apache License 2.0](LICENSE). Third-party
components retain their own licenses.
