# Mistral Vibe for Yumi Smart Pi One (32-bit ARM)

The **official Mistral Vibe CLI** running on **Allwinner H3 / armv7l** (Smart Pi
One, Yumi SmartPad) — a 1 GB, 32-bit board that most modern agentic CLIs won't
touch.

Unlike its sister projects (grok, claude), Vibe needs **no emulation and no
version pinning**: it is a **Python application distributed through uv**, and the
official installer runs on armv7l as-is. The only catch on armhf is that a few
dependencies have no prebuilt wheel and compile from C source — this repo wraps
that so the H3 doesn't overheat, and fixes the `PATH` pitfall the official
installer leaves behind. Sign in with a **Mistral API key** (no local model
required — the LLM runs on Mistral's servers).

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

Mistral Vibe 2.21.0 · armv7l · Python via uv
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/vibe-cli-smartpi/main/install.sh | bash
```

Run it as your **normal user** (not root) — Vibe installs into `~/.local`; `sudo`
is used only for the apt build dependencies. First install compiles native
wheels and takes **~15 min** on the H3 (bound to 2 cores; see below).

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
  `{"cli":"vibe","installed":"2.20.0","latest":"2.21.0","update_available":true}`.
  This is the probe the [Yumi AI Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway)
  console polls for its update badge.
- **Update:** re-run `install.sh` — that IS the updater: already installed →
  `uv tool upgrade mistral-vibe` (fast no-op when current), then the `VIBE_CPUS`
  wrapper is restored. `VIBE_FORCE=1` re-runs the full official installer
  (repair).
- ⚠️ **Never run a bare `uv tool upgrade mistral-vibe`** (or `vibe
  --check-upgrade`'s install path): an upgrade rewrites `~/.local/bin/vibe` and
  drops the wrapper — `install.sh` restores it.
- **Privileges:** everything lives under `$HOME` — no sudo needed after the
  first install (apt build deps): the gateway service user updates unprivileged.

## How it works

1. Vibe ships as a **Python package installed with uv** (`uv tool install
   mistral-vibe`). uv itself is a native armv7 binary — no bootstrap problem —
   and the whole app runs **natively**, no QEMU, no arch check to defeat.
2. On armhf, five dependencies have **no prebuilt wheel** and compile from C with
   the system gcc: `tree-sitter`, `tree-sitter-bash`, `zstandard`, `cffi`,
   `pyyaml`. `cryptography` and `pydantic-core` *do* ship armv7l wheels, so there
   is **no Rust build** — the classic armhf pain point is avoided.
3. Two `taskset`/`nice` core knobs (mirroring `KIMI_*` / `GROK_CPUS` on the sister
   repos), both defaulting to **all 4 cores** (the Yumi build bench has a fan):
   - **`VIBE_BUILD_CPUS`** — cores for the one-off wheel compile above.
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
   **Python client cold start**: each `vibe -p` pays ~17 s of A7 CPU before the
   answer (see measurements below), so an already-open interactive session is the
   better fit for multi-turn work. `earlyoom` is installed as a memory safety net.

Full details (dependency-by-dependency wheel table, thermal measurements, auth
pitfalls, dead ends): [docs/METHODOLOGY.md](docs/METHODOLOGY.md)

## Target hardware & measured performance

Tested on a Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM,
Debian 13 trixie armhf, `vibe 2.21.0`, `uv 0.11.26`) on 2026-07-17. Any armv7l
SBC with ≥ 1 GB RAM should work. Measured:

- **First install**: ~14 min end-to-end measured at **2 cores**
  (`VIBE_BUILD_CPUS=0,1`, the fanless setting; +2–3 min if the apt build deps
  aren't already present). The default is 4 cores (faster, fan bench).
- **`vibe --version`**: 6.8 s (Python cold start).
- **One-shot `vibe -p "short prompt"`**: **~20–21 s** end-to-end (measured twice,
  with a real key). Of that, **~17 s is board CPU** — the Python client cold-start
  and agent-loop orchestration on the Cortex-A7 — and only a few seconds is the
  Mistral API round-trip. The board never runs the inference (model
  `mistral-vibe-cli-latest` is server-side), but the client itself is the cost on
  a 32-bit A7. An already-running interactive `vibe` session avoids paying that
  cold start on every turn.
- **Temperature**: 68 °C idle, ~87 °C peak during the wheel compile (2 cores,
  kernel thermal throttling holds it there), back to ~70 °C at rest; a one-shot
  stays around 85 °C (no inference on-board).

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

All four are driven together by the [Yumi AI
Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway).

## Licensing

- Scripts in this repo: MIT (Yumi Lab).
- Mistral Vibe itself is installed from the official Mistral distribution (via
  uv) at install time — it is not redistributed here and remains subject to
  Mistral AI's terms of service.
