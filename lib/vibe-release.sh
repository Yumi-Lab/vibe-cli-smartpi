# shellcheck shell=sh
# vibe-release.sh — sourced by install.sh AND vibe-check-update: the one place
# that decides which Mistral Vibe this armv7l board installs (POSIX sh).
#
# VIBE_PIN — the Vibe release validated on a real Smart Pi. The installer never
#   installs anything else, so a new upstream release can't break it: since
#   2.25.1 Vibe needs a native Rust harness Mistral builds for x86_64/aarch64
#   only, and 2.25.5 added a C dependency (miniaudio) that compiles with c++ —
#   each broke fresh installs overnight. To move up: test on a pad with
#   `VIBE_VERSION=x.y.z bash install.sh`, then bump VIBE_PIN here; every pad's
#   update badge (vibe-check-update reads this line on GitHub) lights up.
# UV_FIND_LINKS — Yumi's pre-built armv7l wheels (tree-sitter, zstandard, cffi,
#   pyyaml…): C extensions PyPI ships no armv7l wheel for, downloaded instead of
#   compiled on the H3 (~80 min → seconds).
# UV_NO_BUILD_PACKAGE — never build mistral-vibe itself from source: a
#   VIBE_VERSION override with no armv7l wheel fails in seconds in the resolver
#   instead of a long, hot build that dies on cargo.
VIBE_PIN=2.25.0
VIBE_PKG=mistral-vibe
# shellcheck disable=SC2034  # read by vibe-check-update
VIBE_RAW="https://raw.githubusercontent.com/Yumi-Lab/vibe-cli-smartpi/main"
VIBE_VERSION="${VIBE_VERSION:-$VIBE_PIN}"
export UV_FIND_LINKS="${VIBE_WHEELS:-https://raw.githubusercontent.com/Yumi-Lab/smartpi-wheels/main/index.html}"
export UV_NO_BUILD_PACKAGE="$VIBE_PKG"
