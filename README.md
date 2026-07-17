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

Then give it a **Mistral API key** (create one at
[console.mistral.ai](https://console.mistral.ai/) → API keys):

```bash
vibe --setup                              # full-screen wizard, stores the key
# — or, fully headless:
mkdir -p ~/.vibe && echo 'MISTRAL_API_KEY=sk-...' >> ~/.vibe/.env
# — or per-shell:
export MISTRAL_API_KEY=sk-...
```

## Usage

| Command | Purpose |
|---|---|
| `vibe` | **Full interactive TUI** — type a prompt to start, tool approval, sessions |
| `vibe -p "question"` | One-shot answer (programmatic mode: reads/writes files, runs commands) |
| `vibe -p "task" --yolo` | One-shot, auto-approving every tool call (`--auto-approve` alias) |
| `vibe --output streaming -p "…"` | One-shot with newline-delimited JSON events |
| `vibe -c` / `vibe --resume` | Continue / pick a previous session |
| `vibe --setup` | Set the Mistral API key (full-screen wizard) |
| `vibe --check-upgrade` | Check for a Vibe update and (optionally) install it |

⚠️ If `vibe` is **"command not found"** after reconnecting, open a new shell or
run `. ~/.profile` — the installer adds `~/.local/bin` to your `PATH` (the
official installer doesn't).

## How it works

1. Vibe ships as a **Python package installed with uv** (`uv tool install
   mistral-vibe`). uv itself is a native armv7 binary — no bootstrap problem —
   and the whole app runs **natively**, no QEMU, no arch check to defeat.
2. On armhf, four dependencies have **no prebuilt wheel** and compile from C
   with the system gcc: `tree-sitter`, `tree-sitter-bash`, `zstandard`, `cffi`,
   `pyyaml`. We bind that build to **2 cores** (`taskset`): a 4-core gcc build
   once drove this H3 to 102 °C and froze the machine; 2 cores peaks ~87 °C.
   `cryptography` and `pydantic-core` *do* ship armv7l wheels, so there is **no
   Rust build** — the classic armhf pain point is avoided.
3. The official installer drops `uv`/`vibe` in `~/.local/bin` but **never adds it
   to the login-shell `PATH`** — a real trap (`vibe: command not found` after a
   reconnect). The installer here appends it to `~/.bashrc` and `~/.profile`.
4. Vibe is a **thin client**: the model (`mistral-vibe-cli-latest`) runs on
   Mistral's servers, so the H3 only orchestrates the agent loop (tool calls,
   file I/O, parsing). This makes it comfortable for long multi-turn agentic work
   on the pad — the board never carries the inference, so it doesn't overheat the
   way the emulated grok CLI does. `earlyoom` is installed as a memory safety net.

Full details (dependency-by-dependency wheel table, thermal measurements, auth
pitfalls, dead ends): [docs/METHODOLOGY.md](docs/METHODOLOGY.md)

## Target hardware & measured performance

Tested on a Yumi SmartPad (Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM,
Debian 13 trixie armhf, `vibe 2.21.0`, `uv 0.11.26`) on 2026-07-17. Any armv7l
SBC with ≥ 1 GB RAM should work. Measured:

- **First install**: ~14 min end-to-end (2-core compile; +2–3 min if the apt
  build deps aren't already present).
- **`vibe --version`**: 6.8 s (Python cold start).
- **Startup temperature**: 68 °C idle, ~87 °C peak during the wheel compile
  (2 cores, kernel thermal throttling holds it there), back to 70 °C at rest.
- **One-shot / interactive latency** is dominated by the **Mistral API** (network
  round-trip + server-side generation), *not* the board — the H3 runs only the
  thin Python client. The auth path was verified end-to-end against
  `api.mistral.ai` (model `mistral-vibe-cli-latest`).

On 1 GB of RAM with SD-card swap, memory exhaustion freezes the machine before
the kernel OOM killer reacts — the installer enables **earlyoom**. Rule on the
pad: one heavy CLI at a time.

## Sister projects (same board, other CLIs)

- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — official xAI
  Grok CLI, via QEMU 64-on-32 emulation of the static Rust binary.
- [claude-code-smartpi](https://github.com/Yumi-Lab/claude-code-smartpi) —
  official Anthropic Claude Code, native (pinned to the last pure-JS npm release).
- [kimi-cli-smartpi](https://github.com/Yumi-Lab/kimi-cli-smartpi) — Moonshot
  Kimi CLI, native Python via uv (same distribution model as Vibe).

All four are driven together by the [Yumi AI
Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway).

## Licensing

- Scripts in this repo: MIT (Yumi Lab).
- Mistral Vibe itself is installed from the official Mistral distribution (via
  uv) at install time — it is not redistributed here and remains subject to
  Mistral AI's terms of service.
