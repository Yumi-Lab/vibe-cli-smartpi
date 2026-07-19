#!/usr/bin/env bash
# Official Mistral Vibe CLI on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/vibe-cli-smartpi/main/install.sh | bash
#
# This script installs:
#   ~/.local/bin/uv                       Mistral Vibe via uv (official installer)
#   ~/.local/bin/vibe                     runtime wrapper (cores via VIBE_CPUS)
#   ~/.local/bin/vibe-signin              headless browser sign-in helper
#   ~/.local/bin/vibe-check-update        update probe (JSON one-liner, OTA contract)
#   apt build deps                        so the native wheels compile on armhf
#   ~/.local/bin on PATH                  (the official installer does NOT add it)
#   earlyoom                              anti-freeze memory safety net (1 GB RAM)
#
# OTA contract (shared by every Yumi-Lab/*-smartpi repo):
#   * re-running this script IS the update: already installed → `uv tool upgrade
#     mistral-vibe` (fast no-op when current), then the VIBE_CPUS wrapper is
#     restored (an upgrade rewrites ~/.local/bin/vibe). VIBE_FORCE=1 re-runs the
#     full official installer instead;
#   * `vibe-check-update` prints one JSON line {installed, latest,
#     update_available} — what the Yumi AI Gateway polls for its update badge;
#   * everything lives under $HOME → no sudo needed after the first install
#     (apt build deps): the gateway service user updates unprivileged.
#
# Vibe is a Python application distributed through uv, not a prebuilt binary — so
# unlike its 64-bit-only sister CLIs (grok, claude), the OFFICIAL installer runs
# on armv7l as-is. The catch is that a few dependencies have no armv7l wheel and
# are compiled from C source (tree-sitter, zstandard, cffi, pyyaml).
#
# Two core-control knobs, matching kimi-cli-smartpi (KIMI_*) / grok-cli-smartpi:
#   VIBE_BUILD_CPUS   cores for the one-off wheel COMPILE (this installer)
#   VIBE_CPUS         cores for the RUNNING agent (the vibe wrapper, at any time)
# See docs/METHODOLOGY.md for the reasoning behind every choice.
set -euo pipefail

# Cores for the (hot) one-off wheel compilation. Default: all 4 — fast, and the
# Yumi build bench adds a fan for these jobs. On a FANLESS H3 a 4-core gcc build
# drives the SoC to ~102 °C and freezes it, so drop the count on a bare board:
#   VIBE_BUILD_CPUS=0,1  curl -fsSL …/install.sh | bash   # 2 cores (~87 °C peak)
#   VIBE_BUILD_CPUS=0    curl -fsSL …/install.sh | bash   # 1 core  (coolest, slowest)
BUILD_CPUS="${VIBE_BUILD_CPUS:-0,1,2,3}"
VIBE_INSTALLER="https://mistral.ai/vibe/install.sh"
# Real uv-tool binary behind ~/.local/bin/vibe (which we turn into a wrapper).
VIBE_TOOL_BIN="$HOME/.local/share/uv/tools/mistral-vibe/bin/vibe"
RAW="https://raw.githubusercontent.com/Yumi-Lab/vibe-cli-smartpi/main"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"

log()  { printf '\033[1;36m[vibe-smartpi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[vibe-smartpi]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[vibe-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || fail "Run as your normal user, NOT root — Vibe installs into \$HOME/.local (sudo is used only for apt)."
[ "$(uname -m)" = "armv7l" ] || fail "This script targets armv7l (detected: $(uname -m)). On 64-bit just use the official installer: curl -LsSf $VIBE_INSTALLER | bash"
command -v curl >/dev/null || fail "curl is required"

export PATH="$HOME/.local/bin:$PATH"   # uv and vibe live here; make them visible now

THROTTLE="taskset -c $BUILD_CPUS nice -n 5"

# apt is possible when: root (n/a here), passwordless sudo, or an interactive
# run where sudo can prompt on the tty. The gateway service user (no sudo, no
# tty) skips apt cleanly — the gateway installer set the build deps up as root.
can_apt() {
  command -v apt-get >/dev/null || return 1
  sudo -n true 2>/dev/null && return 0
  [ -t 1 ] && command -v sudo >/dev/null
}

# Fetch a repo file: local copy if run from a clone, otherwise raw GitHub.
# Target lives under $HOME (user-owned) — no sudo.
fetch_user() { # $1 repo-relative path, $2 destination
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    install -m755 "$HERE/$1" "$2"
  else
    tmpf=$(mktemp); curl -fsSL "$RAW/$1" -o "$tmpf" && install -m755 "$tmpf" "$2"; rm -f "$tmpf"
  fi
}

# 1. Build dependencies. Vibe compiles native wheels on armhf (no prebuilt
#    armv7l wheels for tree-sitter, zstandard, cffi, pyyaml): python3-dev + gcc
#    + libffi-dev + pkg-config are needed, libjpeg/zlib for the imaging deps.
#    cryptography and pydantic-core DO ship armv7l wheels — no Rust build here.
if can_apt; then
  log "Installing build dependencies (apt)…"
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    python3 python3-dev python3-venv \
    gcc libffi-dev pkg-config libjpeg-dev zlib1g-dev \
    curl ca-certificates >/dev/null
else
  warn "apt unavailable (no sudo/tty) — assuming python3-dev, gcc, libffi-dev, pkg-config, libjpeg and zlib headers are already installed."
fi

# 2. Mistral Vibe via its official installer (which also brings uv into
#    ~/.local/bin). Idempotent: keyed on the uv-tool venv binary, NOT on
#    ~/.local/bin/vibe (step 2b turns that into a wrapper).
#    Already installed → re-run = UPDATE: `uv tool upgrade` (fast no-op when
#    current; only a real upgrade recompiles wheels, throttled like the install).
#    VIBE_FORCE=1 re-runs the full official installer instead.
if [ -x "$VIBE_TOOL_BIN" ] && [ -n "${VIBE_FORCE:-}" ]; then
  log "Vibe present — VIBE_FORCE set, reinstalling via the official installer on cores ${BUILD_CPUS}…"
  curl -LsSf "$VIBE_INSTALLER" | $THROTTLE bash
elif [ -x "$VIBE_TOOL_BIN" ]; then
  log "Vibe already installed ($("$VIBE_TOOL_BIN" --version 2>/dev/null | head -1)) — checking for an upgrade…"
  command -v uv >/dev/null || fail "uv not found on PATH — re-run with VIBE_FORCE=1 to repair."
  $THROTTLE uv tool upgrade mistral-vibe || warn "uv tool upgrade failed — keeping the installed version."
else
  log "Installing Mistral Vibe via uv — compiles native wheels on cores ${BUILD_CPUS}, ~15 min on the H3…"
  curl -LsSf "$VIBE_INSTALLER" | $THROTTLE bash \
    || fail "Vibe installer failed (see the output above)."
  [ -x "$VIBE_TOOL_BIN" ] || fail "Vibe venv not found at $VIBE_TOOL_BIN after install."
fi

# 2b. Runtime core control (VIBE_CPUS). Replace uv's ~/.local/bin/vibe symlink
#     with a wrapper that pins the RUNNING agent to a configurable set of cores —
#     the runtime counterpart of GROK_CPUS / KIMI_CPUS. Default: all 4. On a
#     fanless board running a heavy agentic loop, throttle without reinstalling:
#         VIBE_CPUS=0,1 vibe …
#     The wrapper always calls the real venv binary (never itself → no recursion).
#     NB: `uv tool upgrade mistral-vibe` (or --check-upgrade) rewrites this symlink,
#     so re-run install.sh after an upgrade to restore the wrapper.
mkdir -p "$HOME/.local/bin"
WRAP="$HOME/.local/bin/vibe"
[ -x "$VIBE_TOOL_BIN" ] || fail "real vibe binary missing at $VIBE_TOOL_BIN — cannot build wrapper."
# CRITICAL: ~/.local/bin/vibe is a SYMLINK to $VIBE_TOOL_BIN. `cat > "$WRAP"`
# would FOLLOW it and overwrite the real venv binary with a wrapper that points
# to itself → infinite taskset/nice recursion. `rm -f` removes the link itself
# (never the target), so we then create a fresh regular file at the link's place.
rm -f "$WRAP"
cat > "$WRAP" <<EOF
#!/bin/sh
# vibe-cli-smartpi runtime wrapper — cores set by VIBE_CPUS (default: all 4).
exec taskset -c "\${VIBE_CPUS:-0,1,2,3}" nice -n 5 "$VIBE_TOOL_BIN" "\$@"
EOF
chmod +x "$WRAP"
log "vibe runtime wrapper installed (VIBE_CPUS default 0,1,2,3)."

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

# 4. Headless browser sign-in helper. `vibe --setup`'s browser option calls
#    webbrowser.open() locally — useless on a pad with no browser. vibe-signin
#    runs the same PKCE flow but prints the URL to approve on another machine.
mkdir -p "$HOME/.local/bin"
if fetch_user bin/vibe-signin "$HOME/.local/bin/vibe-signin"; then
  log "installed vibe-signin (headless browser sign-in helper)"
else
  warn "vibe-signin helper not installed (non-fatal) — use 'vibe --setup' or ~/.vibe/.env."
fi

# 4b. Update probe (OTA contract shared by every *-smartpi repo): one JSON line
#     {installed, latest, update_available} — polled by the Yumi AI Gateway.
if fetch_user bin/vibe-check-update "$HOME/.local/bin/vibe-check-update"; then
  log "installed vibe-check-update (update probe)"
else
  warn "vibe-check-update not installed (non-fatal)."
fi

# 5. Anti-freeze safety net: kills the largest process before memory exhaustion
#    (1 GB of RAM + SD-card swap = full machine freeze otherwise). Optional —
#    skipped cleanly when apt/sudo is unavailable (unprivileged OTA update).
if can_apt; then
  sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
    && sudo systemctl enable --now earlyoom >/dev/null 2>&1 \
    && log "earlyoom active" || true
fi

export PATH="$HOME/.local/bin:$PATH"
hash -r 2>/dev/null || true
# Runs through the wrapper (taskset/nice) — proves it's wired.
log "Check: $(timeout 25 vibe --version 2>/dev/null || echo 'vibe --version did not answer — open a new shell')"

cat <<'MSG'

Install complete.

Sign in — two ways (both work headless):
  a) Browser sign-in (no key to copy), best on a pad with no browser:
    vibe-signin                           prints a console.mistral.ai URL to approve
                                          on any machine, then writes ~/.vibe/.env
  b) API key directly (get one at https://console.mistral.ai/ → API keys):
    vibe --setup                          full-screen wizard → "Enter API key"
    mkdir -p ~/.vibe && echo 'MISTRAL_API_KEY=...' >> ~/.vibe/.env    # or headless
    export MISTRAL_API_KEY=...                                        # or per-shell

Usage:
    vibe                      full interactive TUI (type a prompt to start)
    vibe -p "question"        one-shot answer (programmatic mode)
    vibe -p "task" --yolo     one-shot, auto-approving every tool call
    vibe --version            sanity check (~7 s cold start on the H3)

    VIBE_CPUS=0,1 vibe …      limit the running agent to 2 cores (default: all 4)

Notes:
    * If `vibe` is "not found" after reconnecting: open a new shell, or run
      `. ~/.profile` — the installer just added ~/.local/bin to your PATH.
    * To upgrade later: just re-run install.sh (already installed → uv tool
      upgrade + wrapper restored). Check first with vibe-check-update.
      VIBE_FORCE=1 re-runs the full official installer (repair).
    * NEVER a bare `uv tool upgrade mistral-vibe`: it rewrites ~/.local/bin/vibe
      and drops the VIBE_CPUS wrapper — install.sh restores it.
    * Keep one heavy CLI at a time on a 1 GB board; earlyoom is the safety net.
MSG
