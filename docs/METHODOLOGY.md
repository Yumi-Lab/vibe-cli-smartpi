# Full methodology — official Mistral Vibe CLI on 32-bit ARM

How to run Mistral's agentic CLI on a SoC that can only execute 32-bit code
(Allwinner H3, Cortex-A7, armv7l, 1 GB RAM). Reference document: every choice
below was tested on a Yumi SmartPad (quad-core H3 @ 1.2 GHz, Debian 13 trixie
armhf) on 2026-07-17 with `vibe 2.21.0` and `uv 0.11.26`.

## 1. Why this one is different

The sister projects on this board fight a **binary distribution problem**:

- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — the CLI is a
  64-bit static Rust binary → QEMU 64-on-32 user-mode emulation.
- [claude-code-smartpi](https://github.com/Yumi-Lab/claude-code-smartpi) — modern
  releases are 64-bit Bun binaries → pin the last pure-JS npm version.

Vibe has **no such problem**. It is a plain **Python application distributed
through uv** (`uv tool install mistral-vibe`, pulled from Mistral's repository).
Python runs natively on armv7l, uv publishes a native `armv7-unknown-linux-
gnueabihf` binary, and the official installer
(`curl -LsSf https://mistral.ai/vibe/install.sh | bash`) has **no architecture
gate**. It just works — almost. The two real issues on armhf are (a) a handful of
C-extension dependencies with no prebuilt wheel, which compile on-device and heat
the SoC, and (b) a `PATH` that the installer never wires up.

## 2. The distribution model (uv, native)

The official installer does two things:

1. Installs **uv** via Astral's installer if absent — on this board it fetches
   `uv 0.11.26 armv7-unknown-linux-gnueabihf` into `~/.local/bin` (native, no
   compile).
2. Runs `uv tool install mistral-vibe`, which resolves ~94 packages and installs
   Vibe into an isolated tool environment
   (`~/.local/share/uv/tools/mistral-vibe`), exposing `~/.local/bin/vibe` as a
   symlink.

No venv juggling, no `--system-site-packages` tricks (unlike the gateway's own
install, which shares apt's `python3-cryptography`): uv's isolated environment
pulls everything it needs from PyPI, and on armv7l that means **building the
wheels that PyPI doesn't pre-build**.

## 3. What compiles, and what doesn't

Observed during a clean `uv tool install mistral-vibe` on the H3:

| Dependency | armv7l wheel on PyPI? | On the H3 |
|---|---|---|
| `cryptography` | ✔ yes | downloaded, no build |
| `pydantic-core` | ✔ yes (no Rust build!) | downloaded, no build |
| `mistralai`, `pygments`, … | ✔ pure-python | downloaded |
| `tree-sitter` 0.26 | ✖ | **compiled** (C) |
| `tree-sitter-bash` 0.25 | ✖ | **compiled** (C) |
| `zstandard` 0.25 | ✖ | **compiled** (C, bundles the whole zstd source — the slowest single wheel) |
| `cffi` 2.0 | ✖ | **compiled** (C) |
| `pyyaml` 6.0.3 | ✖ | **compiled** (C) |

The important good news: **`cryptography` and `pydantic-core` ship armv7l
wheels**, so there is **no Rust toolchain build** — the usual armhf nightmare
(compiling `cryptography`'s Rust backend on 1 GB of RAM) never happens. Only C
extensions are built, and those need only:

```
python3-dev  gcc  libffi-dev  pkg-config  libjpeg-dev  zlib1g-dev
```

(`libjpeg`/`zlib` cover the imaging path; the rest cover cffi/tree-sitter/yaml.)
The build uses Debian trixie's own `arm-linux-gnueabihf-gcc 14` — no third-party
repo, no cross-compilation.

## 4. Thermals: two core knobs (build + runtime)

The single real hazard is heat. Both the wheel compile *and* a heavy agent loop
can pin all four cores, and a sustained 4-core load on the passively-cooled H3 is
exactly the workload that **drove this same pad to 102 °C and froze it** (measured
incident, documented in the grok methodology). So — matching `KIMI_BUILD_CPUS` /
`KIMI_CPUS` on kimi-cli-smartpi and `GROK_CPUS` on grok-cli-smartpi — this repo
exposes two `taskset -c … nice -n 5` knobs, **both defaulting to all 4 cores**
(fast; the Yumi build bench adds a fan). On a **fanless** board, drop them.

**`VIBE_BUILD_CPUS`** — the one-off wheel compile. The installer wraps the whole
official installer, and `taskset` affinity is inherited by every child (uv, gcc,
cc1), so the compile stays on the chosen cores:

```
curl -LsSf https://mistral.ai/vibe/install.sh | taskset -c "$VIBE_BUILD_CPUS" nice -n 5 bash
```

Measured at **2 cores** (`VIBE_BUILD_CPUS=0,1`, the safe fanless setting):

- Peak **~87 °C** during the C builds (kernel passive throttling holds it there;
  chassis throttles from 75 °C, trip points at 75/80/85/90 °C).
- Back to **70 °C** within a minute of finishing.
- Total wall time **14 min 01 s** (user 16 min 14 s — i.e. ~1.15× parallelism on
  the 2 permitted cores). Four cores (with a fan) roughly halves that.

**`VIBE_CPUS`** — the *running* agent. uv exposes `~/.local/bin/vibe` as a symlink
to the tool venv; the installer **replaces it with a wrapper** that pins every run:

```sh
#!/bin/sh
exec taskset -c "${VIBE_CPUS:-0,1,2,3}" nice -n 5 \
  "$HOME/.local/share/uv/tools/mistral-vibe/bin/vibe" "$@"
```

So `VIBE_CPUS=0,1 vibe …` throttles a live agent with no reinstall (the affinity
is inherited by vibe's tool subprocesses too). The wrapper always calls the real
venv binary — never itself, so no recursion. **Caveat:** `uv tool upgrade
mistral-vibe` (and `vibe --check-upgrade`) rewrites that symlink back, dropping the
wrapper — re-run `install.sh` afterwards to restore it. Idempotence is therefore
keyed on the venv binary (`…/uv/tools/mistral-vibe/bin/vibe`), **not** on
`~/.local/bin/vibe`.

## 5. The PATH trap

The official installer places `uv` and `vibe` in `~/.local/bin` but **writes no
PATH line to any shell rc**. On a fresh reconnect:

```
$ bash -lc 'command -v vibe'      → (nothing: vibe not found)
```

This is the same pitfall already hit inside the Yumi AI Gateway. The installer
here appends

```sh
export PATH="$HOME/.local/bin:$PATH"
```

to `~/.bashrc` and `~/.profile` (idempotently — it checks for `.local/bin`
first). A running session still needs `. ~/.profile` or a new shell.

## 6. Authentication — two methods, both verified

Vibe ends up needing a **Mistral API key**, but there are **two ways** to get one
onto the board (both tested on the pad on 2026-07-17). The `vibe --setup` wizard
(`vibe/setup/onboarding/…`) has an `auth_method` screen that offers exactly these.

### 6a. Browser sign-in (PKCE) — the "give me a link" flow

Yes, Vibe **does** have a browser sign-in flow (contrary to a first read of the
error message). Reconstructed from `vibe/setup/auth/http_browser_sign_in_gateway.py`
and reproduced end-to-end on the pad:

1. Generate a PKCE pair: `verifier = secrets.token_urlsafe(64)`,
   `challenge = base64url(sha256(verifier))` (no padding).
2. `POST https://console.mistral.ai/api/vibe/sign-in`
   `{"code_challenge": <challenge>, "code_challenge_method": "S256"}` →
   `{process_id, sign_in_url, poll_url, expires_at}` (no auth header needed —
   it's the browser session that authorises).
3. The `sign_in_url` is
   `https://console.mistral.ai/codestral/cli/authenticate?process_id=…&complete_token=…`
   — open it in any browser logged into a Mistral account, approve (~15 min TTL).
4. Poll `GET {poll_url}` every 3 s until `status == "completed"` (→ `exchange_token`);
   `410 Gone` = expired.
5. `POST https://console.mistral.ai/api/vibe/sign-in/{process_id}/exchange`
   `{"exchange_token", "code_verifier"}` → `{"api_key": "…"}` (a 32-char key).
6. Persist it: keyring first, else `~/.vibe/.env` (`vibe/setup/auth/api_key_persistence.py`).

The native `vibe --setup` browser option calls `webbrowser.open()` **locally** —
useless on a headless pad (no browser, no `$DISPLAY`), and it raises if it can't
open. So this repo ships **`vibe-signin`**, a stdlib-only helper that runs the
exact flow above but *prints* the URL (to open on another machine) and writes the
key to `~/.vibe/.env`. Base URLs live in `vibe/core/config/_defaults.py`
(`console.mistral.ai`, overridable via `VIBE_*`).

### 6b. API key directly

1. **`vibe --setup`** → *Enter API key* (full-screen TUI, needs a real terminal).
2. **`~/.vibe/.env`** — `MISTRAL_API_KEY=...` on its own line. Best headless.
3. **Shell env** — `export MISTRAL_API_KEY=...`.

The exact, verified error when no key is set:

```
Error: Missing MISTRAL_API_KEY environment variable for mistral provider.
Set the environment variable (e.g. in ~/.vibe/.env or your shell), or run
`vibe --setup` once interactively.
```

With a (deliberately wrong) key, the request reaches Mistral and comes back:

```
Error: API error from mistral (model: mistral-vibe-cli-latest): Invalid API key.
```

— which confirms both that `MISTRAL_API_KEY` from the environment is honoured and
that the default model is **`mistral-vibe-cli-latest`** (a hosted model — the
board carries none of the inference). Get a key at
[console.mistral.ai](https://console.mistral.ai/) → API keys.

## 7. Installed layout

```
~/.local/bin/uv, ~/.local/bin/uvx                  native armv7 uv (installer)
~/.local/bin/vibe                                   VIBE_CPUS wrapper → tool venv binary (this repo)
~/.local/bin/vibe-signin                            headless browser sign-in helper (this repo)
~/.local/share/uv/tools/mistral-vibe/bin/vibe      the REAL Vibe binary (uv tool venv)
~/.local/share/uv/tools/mistral-vibe/              isolated tool environment
~/.vibe/config.toml                                created on first run
~/.vibe/.env                                        MISTRAL_API_KEY (recommended)
~/.vibe/trusted_folders.toml                        per-folder trust
~/.vibe/logs/vibe.log                               logs (LOG_LEVEL to tune)
~/.vibe/agents/NAME.toml                            custom agents (--agent NAME)
```

Useful environment variables (from `vibe --help`): `VIBE_HOME` (override
`~/.vibe`), `VIBE_*` to override any config field (e.g.
`VIBE_ACTIVE_MODEL=local`), `LOG_LEVEL`.

## 8. Performance and memory (1 GB H3)

Measured on the SmartPad:

- `vibe --version`: **6.8 s** (Python cold start of the client).
- **One-shot `vibe -p "short prompt"`: ~20–21 s** (measured twice with a real key:
  21.0 s and 20.3 s wall). The revealing part is the split: **user CPU ≈ 17 s**,
  i.e. most of the wall time is the **board** running the Python client (cold
  start + agent-loop init + request/response handling on a Cortex-A7), *not* the
  Mistral API. The model runs server-side, so the board never carries the
  inference (temp stays ~85 °C, no runaway) — but the client itself is the tax,
  and it is paid on **every** `vibe -p`. Keep an interactive `vibe` session open
  for multi-turn work to amortise the cold start.
- Correcting an earlier assumption: this latency is **board-bound, not
  API-bound** — the naive "it's just a thin client, the pad does nothing" is wrong
  by ~17 s.

On 1 GB of RAM with SD-card swap, memory exhaustion freezes the machine before
the OOM killer reacts — the installer enables **earlyoom**. Operating rules:
one heavy CLI at a time, and bound batch workloads
(`systemd-run --scope -p MemoryMax=600M`, `timeout`).

## 9. Maintenance

- **Upgrading**: re-run `install.sh` with `VIBE_FORCE=1` (re-runs the official
  installer through the 2-core throttle), or `vibe --check-upgrade`. uv caches
  the already-built wheels, so a re-run is far quicker than the first 14 min.
- **Idempotency**: without `VIBE_FORCE`, `install.sh` detects an existing `vibe`
  and skips the compile — it still repairs the PATH lines and earlyoom.
- **`taskset` is only about heat**: on a board with a heatsink/fan, drop it
  (`VIBE_BUILD_CPUS=0,1,2,3`) to cut install time roughly in half.
- Check thermal health after heavy use:
  `cat /sys/class/thermal/thermal_zone0/temp`.
