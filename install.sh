#!/usr/bin/env bash
# Official Mistral Vibe CLI on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/vibe-cli-smartpi/main/install.sh | bash
#
# This script installs:
#   ~/.local/bin/uv, ~/.local/bin/vibe   Mistral Vibe via uv (official installer)
#   apt build deps                        so the native wheels compile on armhf
#   ~/.local/bin on PATH                  (the official installer does NOT add it)
#   earlyoom                              anti-freeze memory safety net (1 GB RAM)
#
# Vibe is a Python application distributed through uv, not a prebuilt binary — so
# unlike its 64-bit-only sister CLIs (grok, claude), the OFFICIAL installer runs
# on armv7l as-is. The catch is that a few dependencies have no armv7l wheel and
# are compiled from C source (tree-sitter, zstandard, cffi, pyyaml) — we bind that
# gcc build to 2 cores so the H3 doesn't cook itself.
# See docs/METHODOLOGY.md for the reasoning behind every choice.
set -euo pipefail

# Bind the native-wheel compilation to 2 cores. A 4-core gcc build once drove
# the H3 to 102 °C (machine freeze); 2 cores peaks around 87 °C. Override with
# VIBE_BUILD_CPUS=0,1,2,3 on a cooled board.
BUILD_CPUS="${VIBE_BUILD_CPUS:-0,1}"
VIBE_INSTALLER="https://mistral.ai/vibe/install.sh"

log()  { printf '\033[1;36m[vibe-smartpi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vibe-smartpi]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[vibe-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "Run as your normal user, NOT root — Vibe installs into \$HOME/.local (sudo is used only for apt)."
[ "$(uname -m)" = "armv7l" ] || fail "This script targets armv7l (detected: $(uname -m)). On 64-bit just use the official installer: curl -LsSf $VIBE_INSTALLER | bash"
command -v curl >/dev/null || fail "curl is required"

THROTTLE="taskset -c $BUILD_CPUS nice -n 5"

# 1. Build dependencies. Vibe compiles native wheels on armhf (no prebuilt
#    armv7l wheels for tree-sitter, zstandard, cffi, pyyaml): python3-dev + gcc
#    + libffi-dev + pkg-config are needed, libjpeg/zlib for the imaging deps.
#    cryptography and pydantic-core DO ship armv7l wheels — no Rust build here.
log "Installing build dependencies (apt)…"
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    python3 python3-dev python3-venv \
    gcc libffi-dev pkg-config libjpeg-dev zlib1g-dev \
    curl ca-certificates >/dev/null
else
  warn "apt-get not found — make sure python3-dev, gcc, libffi-dev, pkg-config, libjpeg and zlib headers are installed."
fi

# 2. Mistral Vibe via its official installer (which also brings uv into
#    ~/.local/bin). Idempotent: if vibe is already installed we skip the ~15 min
#    compile — pass VIBE_FORCE=1 to reinstall/upgrade.
if command -v vibe >/dev/null 2>&1 || [ -x "$HOME/.local/bin/vibe" ]; then
  CUR="$("$HOME/.local/bin/vibe" --version 2>/dev/null || vibe --version 2>/dev/null || echo '?')"
  if [ -n "${VIBE_FORCE:-}" ]; then
    log "Vibe already present ($CUR) — VIBE_FORCE set, reinstalling/upgrading…"
    curl -LsSf "$VIBE_INSTALLER" | $THROTTLE bash
  else
    log "Vibe already installed ($CUR) — skipping reinstall (set VIBE_FORCE=1 to upgrade)."
  fi
else
  log "Installing Mistral Vibe via uv — compiles native wheels, ~15 min on the H3 (2 cores)…"
  curl -LsSf "$VIBE_INSTALLER" | $THROTTLE bash \
    || fail "Vibe installer failed (see the output above)."
fi

# 3. PATH fix. The official installer drops uv/vibe into ~/.local/bin but does
#    NOT add it to the PATH of login shells → `vibe: command not found` after a
#    reconnect. Add it to the shell rc files if it isn't there already.
add_path_line() {
  local rc="$1"
  [ -e "$rc" ] || { [ "$rc" = "$HOME/.profile" ] || return 0; }  # create ~/.profile if missing
  grep -qsF '.local/bin' "$rc" 2>/dev/null && return 0
  printf '\n# Added by vibe-cli-smartpi: uv and vibe live here\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
  log "PATH: added ~/.local/bin to $(basename "$rc")"
}
add_path_line "$HOME/.bashrc"
add_path_line "$HOME/.profile"

# 4. Anti-freeze safety net: kills the largest process before memory exhaustion
#    (1 GB of RAM + SD-card swap = full machine freeze otherwise).
if command -v apt-get >/dev/null; then
  sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
    && sudo systemctl enable --now earlyoom >/dev/null 2>&1 \
    && log "earlyoom active" || true
fi

export PATH="$HOME/.local/bin:$PATH"
hash -r 2>/dev/null || true
log "Check: $(vibe --version 2>/dev/null || echo 'vibe not on PATH — open a new shell')"

cat <<'MSG'

Install complete.

Sign in with a Mistral API key (get one at https://console.mistral.ai/ → API keys):
    vibe --setup                          full-screen wizard, stores the key, then exits
  or, fully headless / non-interactive, write it once to ~/.vibe/.env:
    mkdir -p ~/.vibe && echo 'MISTRAL_API_KEY=sk-...' >> ~/.vibe/.env
  or export it in your shell:
    export MISTRAL_API_KEY=sk-...

Usage:
    vibe                      full interactive TUI (type a prompt to start)
    vibe -p "question"        one-shot answer (programmatic mode)
    vibe -p "task" --yolo     one-shot, auto-approving every tool call
    vibe --version            sanity check (~7 s cold start on the H3)

Notes:
    * If `vibe` is "not found" after reconnecting: open a new shell, or run
      `. ~/.profile` — the installer just added ~/.local/bin to your PATH.
    * To upgrade later: re-run this script with VIBE_FORCE=1 (or `vibe --check-upgrade`).
    * Keep one heavy CLI at a time on a 1 GB board; earlyoom is the safety net.
MSG
