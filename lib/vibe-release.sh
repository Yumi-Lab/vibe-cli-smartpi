# shellcheck shell=sh
# vibe-release.sh — sourced by install.sh AND vibe-check-update: the one place
# that decides which Mistral Vibe this armv7l board installs (POSIX sh).
#
# UV_FIND_LINKS — Yumi's pre-built armv7l wheels (tree-sitter, zstandard, cffi,
#   pyyaml…): C extensions PyPI ships no armv7l wheel for, downloaded instead of
#   compiled on the H3 (~80 min → seconds).
# UV_NO_BUILD_PACKAGE — never build mistral-vibe itself from source. Since 2.25.1
#   Vibe needs a native Rust harness that Mistral builds for x86_64/aarch64 only
#   (2.25.1–2.25.5: separate wheel-only package; 2.25.7+: bundled, sdist needs
#   cargo and ~800 crates). uv then skips those releases and installs the newest
#   one with a usable wheel — and moves up by itself once one exists (upstream or
#   in smartpi-wheels). uv stores both settings in the tool receipt, so a bare
#   `uv tool upgrade mistral-vibe` keeps them.
VIBE_PKG=mistral-vibe
export UV_FIND_LINKS="${VIBE_WHEELS:-https://raw.githubusercontent.com/Yumi-Lab/smartpi-wheels/main/index.html}"
export UV_NO_BUILD_PACKAGE="$VIBE_PKG"

# Newest Vibe uv would install here, by the same rule (`uv pip` spells it
# --only-binary). Dry run: resolves, writes nothing. $1 = uv binary.
vibe_latest_installable() {
  timeout 60 "$1" pip install --dry-run --only-binary "$VIBE_PKG" --python python3 \
    --target "${TMPDIR:-/var/tmp}/vibe-probe" "$VIBE_PKG" 2>&1 \
    | sed -n "s/^ + $VIBE_PKG==//p"
}
