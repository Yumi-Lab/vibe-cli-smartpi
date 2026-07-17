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

## 4. Thermals: bind the compile to 2 cores

The single real hazard is heat. A `uv` build parallelises across all cores, and a
sustained 4-core gcc load on the passively-cooled H3 is exactly the workload that
**drove this same pad to 102 °C and froze it** (measured incident, documented in
the grok methodology). So the installer wraps the whole thing:

```
curl -LsSf https://mistral.ai/vibe/install.sh | taskset -c 0,1 nice -n 5 bash
```

`taskset` CPU affinity is inherited by every child (uv, gcc, cc1), so the entire
compile stays on 2 cores. Measured with that throttle:

- Peak **~87 °C** during the C builds (kernel passive throttling holds it there;
  chassis throttles from 75 °C, trip points at 75/80/85/90 °C).
- Back to **70 °C** within a minute of finishing.
- Total wall time **14 min 01 s** (user 16 min 14 s — i.e. ~1.15× parallelism on
  the 2 permitted cores).

Override on a cooled board with `VIBE_BUILD_CPUS=0,1,2,3`.

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

## 6. Authentication (Mistral API key)

Vibe authenticates with a **Mistral API key** — there is **no OAuth / device-code
flow** (unlike grok's `login --device-auth` or claude's `setup-token`). The model
runs server-side, so the key is all that's needed. Verified on the pad, three
equivalent ways:

1. **`vibe --setup`** — a full-screen TUI wizard (alternate-screen, mouse
   tracking) that stores the key and exits. Needs a real terminal.
2. **`~/.vibe/.env`** — `MISTRAL_API_KEY=sk-...` on its own line. Best for
   headless boards.
3. **Shell env** — `export MISTRAL_API_KEY=sk-...`.

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
~/.local/bin/vibe        → ~/.local/share/uv/tools/mistral-vibe/bin/vibe
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
- **One-shot / interactive latency is API-bound, not board-bound.** Vibe is a
  thin client: `mistral-vibe-cli-latest` runs on Mistral's servers, so wall time
  is network round-trip + server generation + local tool execution — largely
  independent of the H3. This is why, unlike the grok/claude pages, no
  board-specific "one-shot ~Xs" figure is quoted: it would measure Mistral's
  infrastructure, not the pad. (The corollary is a genuine advantage — the board
  never carries the inference, so long agentic sessions don't overheat it.)

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
