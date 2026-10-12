# Mistral Vibe for Yumi Smart Pi One (32-bit ARM)

The **official Mistral Vibe CLI** running on **Allwinner H3 / armv7l** (Smart Pi
One, Yumi SmartPad) — a 1 GB, 32-bit board that most modern agentic CLIs won't
touch.

Unlike its sister projects (grok, claude), Vibe needs **no emulation**: it is a
**Python application distributed through uv**, and the official installer runs on
armv7l as-is. This repo handles what armhf breaks: C-extension dependencies with
no armv7l wheel (pulled pre-built instead of compiled on the H3), Vibe releases
that need a native component Mistral doesn't build for armv7l (see **Version
ceiling** below), and the `PATH` pitfall the official installer leaves behind.
Sign in with a **Mistral API key** (no local model required — the LLM runs on
Mistral's servers).

```
██████████████████░░
██████████████████░░
████  ██████  ████░░
████    ██    ████░░
████          ████░░
████  ██  ██  ████░░
██      ██      ██░░
██████████████████░░
██████████████████░░

Mistral Vibe 2.25.0 · armv7l · Python via uv
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/vibe-cli-smartpi/main/install.sh | bash
```

Run it as your **normal user** (not root) — Vibe installs into `~/.local`; `sudo`
is used only for the apt build dependencies. Nothing compiles: a cold install
took **~7 min** on the H3, all of it resolving and downloading 96 packages over a
slow link (measured below).

### Version ceiling

Since **2.25.1** (2026-09-09) Vibe needs a native Rust component (its local
"harness") that Mistral publishes only for x86_64, aarch64, macOS and Windows —
no armv7l build, and from 2.25.7 the only alternative is compiling ~800 Rust
crates on a 1 GB board. So the installer tells uv **never to build
`mistral-vibe` from source**: uv skips those releases and installs the **newest
one that ships a usable wheel — 2.25.0** today (upstream is at 2.26.1). The day
an armv7l build exists (upstream, or pre-built in
[smartpi-wheels](https://github.com/Yumi-Lab/smartpi-wheels)), a plain update
picks it up — there is no version number to bump here.

Then authenticate — Vibe supports **two methods**, both verified on the pad:

**a) Browser sign-in (no API key to copy).** `vibe --setup` → *Sign in with
browser* runs a PKCE flow against `console.mistral.ai`: it mints a one-time
`console.mistral.ai/codestral/cli/authenticate?...` URL, you approve it in any
browser logged into your Mistral account, and Vibe fetches + stores the key
itself. On a **headless pad** the local browser can't open, so this repo ships a
helper that prints the URL for you to open on another machine:

```bash
vibe-signin        # prints the sign-in URL, waits, writes MISTRAL_API_KEY to ~/.vibe/.env
```

**b) API key directly** (create one at
[console.mistral.ai](https://console.mistral.ai/) → API keys):

```bash
vibe --setup                              # full-screen wizard → "Enter API key"
# — or, fully headless:
mkdir -p ~/.vibe && echo 'MISTRAL_API_KEY=...' >> ~/.vibe/.env
# — or per-shell:
export MISTRAL_API_KEY=...
```

## Usage

| Command | Purpose |
|---|---|
| `vibe` | **Full interactive TUI** — type a prompt to start, tool approval, sessions |
| `vibe -p "question"` | One-shot answer (programmatic mode: reads/writes files, runs commands) |
| `vibe -p "task" --yolo` | One-shot, auto-approving every tool call (`--auto-approve` alias) |
| `vibe --output streaming -p "…"` | One-shot with newline-delimited JSON events |
| `vibe -c` / `vibe --resume` | Continue / pick a previous session |
| `vibe --setup` | Sign in (browser or API key) — full-screen wizard |
| `vibe-signin` | **Headless browser sign-in** (this repo): prints the URL, writes the key |
| `VIBE_CPUS=0,1 vibe …` | Pin the running agent to a core subset — no reinstall (default: all 4) |
| `vibe-check-update` | Update probe (this repo): one JSON line `{installed, latest, update_available}` |

⚠️ If `vibe` is **"command not found"** after reconnecting, open a new shell or
run `. ~/.profile` — the installer adds `~/.local/bin` to your `PATH` (the
official installer doesn't).

## Updating (OTA)

- **Check:** `vibe-check-update` prints one JSON line —
  `{"cli":"vibe","installed":"2.24.5","latest":"2.25.0","update_available":true}`.
  `latest` is the newest version **installable on this board** (a uv dry run
  under the same rule as the installer, ~3 s), not PyPI's newest — so the badge
  never asks for an update the installer can't deliver. This is the probe the
  [Yumi AI Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway) console polls.
- **Update:** re-run `install.sh` — that IS the updater: already installed →
  `uv tool upgrade mistral-vibe` (~6 s no-op when current), then the `VIBE_CPUS`
  wrapper is restored. `VIBE_FORCE=1` re-runs the full official installer
  (repair).
- ⚠️ **Prefer `install.sh` over a bare `uv tool upgrade mistral-vibe`** (or `vibe
  --check-upgrade`'s install path): an upgrade rewrites `~/.local/bin/vibe` and
  drops the wrapper — `install.sh` restores it. (The version rule itself
  survives: uv keeps it in the tool's receipt.)
- **Privileges:** everything lives under `$HOME` — no sudo needed after the
  first install (apt build deps): the gateway service user updates unprivileged.

## How it works

1. Vibe ships as a **Python package installed with uv** (`uv tool install
   mistral-vibe`). uv itself is a native armv7 binary — no bootstrap problem —
   and the whole app runs **natively**, no QEMU, no arch check to defeat.
2. Two rules, in one file shared by the installer and the update probe
   ([lib/vibe-release.sh](lib/vibe-release.sh)):
   - **Pre-built wheels.** `tree-sitter`, `tree-sitter-bash`, `zstandard`,
     `cffi`, `pyyaml` have no armv7l wheel on PyPI; Yumi builds them once on real
     hardware and uv pulls them from
     [smartpi-wheels](https://github.com/Yumi-Lab/smartpi-wheels)
     (`UV_FIND_LINKS`; override the index with `VIBE_WHEELS=<url>`).
     `cryptography`, `pydantic-core`, `textual-speedups` ship armv7l wheels — no
     Rust toolchain anywhere.
   - **Never build `mistral-vibe` itself** (`UV_NO_BUILD_PACKAGE`) — the version
     ceiling above.
3. Two `taskset`/`nice` core knobs (mirroring `KIMI_*` / `GROK_CPUS` on the sister
   repos), both defaulting to **all 4 cores** (the Yumi build bench has a fan):
   - **`VIBE_BUILD_CPUS`** — cores for the install; only matters if a wheel is
     missing from the index and compiles from source (apt build deps are kept
     for that fallback).
   - **`VIBE_CPUS`** — cores for the *running* agent (`~/.local/bin/vibe` is a
     wrapper that `exec`s the real uv-tool binary under `taskset`).

   On a **fanless** board, throttle to avoid the freeze — a 4-core gcc build once
   drove this H3 to 102 °C (2 cores peaks ~87 °C):
   ```bash
   VIBE_BUILD_CPUS=0,1 curl -fsSL …/install.sh | bash   # install on 2 cores
   VIBE_CPUS=0,1 vibe -p "…"                             # run the agent on 2 cores
   ```
4. The official installer drops `uv`/`vibe` in `~/.local/bin` but **never adds it
   to the login-shell `PATH`** — a real trap (`vibe: command not found` after a
   reconnect). The installer here appends it to `~/.bashrc` and `~/.profile`.
5. Vibe is a **network client**: the model (`mistral-vibe-cli-latest`) runs on
   Mistral's servers, so the H3 never carries the inference — it doesn't overheat
   the way the emulated grok CLI does (a one-shot stays ~85 °C). The catch is the
   **Python client**: each `vibe -p` pays ~17–20 s of A7 CPU around the answer
   (see measurements below), so an already-open interactive session is the
   better fit for multi-turn work. `earlyoom` is installed as a memory safety net.

Full details (dependency-by-dependency wheel table, thermal measurements, auth
pitfalls, dead ends): [docs/METHODOLOGY.md](docs/METHODOLOGY.md)

## Target hardware & measured performance

Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM, Debian 13 trixie
armhf, `uv 0.11.26`). Any armv7l SBC with ≥ 1 GB RAM should work.

**2026-10-12, `vibe 2.25.0`** (cold install, 4 cores, fan bench, no sudo — the
gateway's path; traffic through a VPN at ~170 KB/s):

- **First install: 7 min 07 s**, no compile at all — 1 min 30 s resolving and
  2 min 37 s fetching 96 packages; the rest is uv's own download. Peak 39 °C.
- **Update when current** (re-run `install.sh`): 6 s. **`vibe-check-update`**: 3 s.
- **`vibe --version`**: 0.56 s (the 2.25 launcher no longer imports the full CLI).
- **One-shot `vibe -p "hi"` up to Mistral's reply**: 23.1 s wall, **19.5 s user
  CPU** (measured with a deliberately invalid key: the request reaches Mistral and
  comes back `Invalid API key` — the full client path, minus the model's answer).
- `VIBE_CPUS=1` / `0,2` verified on the live process (affinity + nice 5).

**2026-07-17, `vibe 2.21.0`** (when 5 wheels still compiled on the board):

- First install 14 min at 2 cores (`VIBE_BUILD_CPUS=0,1`, fanless), ~87 °C peak
  during the compile (kernel throttling holds it there), back to ~70 °C at rest.
- **One-shot with a real key: ~20–21 s** end-to-end (measured twice). Of that,
  **~17 s is board CPU** — the Python client and agent-loop orchestration on the
  Cortex-A7 — and only a few seconds is the Mistral round-trip. The board never
  runs the inference (`mistral-vibe-cli-latest` is server-side; ~85 °C), but the
  client is the cost on a 32-bit A7: keep an interactive `vibe` session open for
  multi-turn work.

On 1 GB of RAM with SD-card swap, memory exhaustion freezes the machine before
the kernel OOM killer reacts — the installer enables **earlyoom**. Rule on the
pad: one heavy CLI at a time.

## Sister projects (same board, other CLIs)

- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — official xAI
  Grok CLI, via QEMU 64-on-32 emulation of the static Rust binary.
- [claude-code-smartpi](https://github.com/Yumi-Lab/claude-code-smartpi) —
  official Anthropic Claude Code, native (pinned to the last pure-JS npm release).
- [kimi-cli-smartpi](https://github.com/Yumi-Lab/kimi-cli-smartpi) — Moonshot Kimi
  CLI, native Python via uv.
- [kimi-code-smartpi](https://github.com/Yumi-Lab/kimi-code-smartpi) — Moonshot Kimi
  Code CLI (the TypeScript successor to kimi-cli), native via npm + Node 22.

All five are driven together by the [Yumi AI
Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway).

## Licensing

- Scripts in this repo: MIT (Yumi Lab).
- Mistral Vibe itself is installed from the official Mistral distribution (via
  uv) at install time — it is not redistributed here and remains subject to
  Mistral AI's terms of service.
