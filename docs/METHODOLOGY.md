# Full methodology — official Mistral Vibe CLI on 32-bit ARM

How to run Mistral's agentic CLI on a SoC that can only execute 32-bit code
(Allwinner H3, Cortex-A7, armv7l, 1 GB RAM). Reference document: every choice
below was tested on a Yumi SmartPad (quad-core H3 @ 1.2 GHz, Debian 13 trixie
armhf) on 2026-07-17 with `vibe 2.21.0` and `uv 0.11.26`; re-validated end to end
on 2026-10-12 with `vibe 2.25.0` — the newest release installable on armv7l (§3b).

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
gate**. It just works — almost. The real issues on armhf are (a) a handful of
C-extension dependencies with no prebuilt wheel, which would compile on-device and
heat the SoC (now pulled pre-built), (b) since 2.25.1, a native Rust component
Mistral doesn't build for armv7l (§3b), and (c) a `PATH` that the installer never
wires up.

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
| `textual-speedups` | ✔ yes | downloaded, no build |
| `mistralai`, `pygments`, … | ✔ pure-python | downloaded |
| `tree-sitter` 0.26 | ✖ | compiled (C) → now **pre-built**, smartpi-wheels |
| `tree-sitter-bash` 0.25 | ✖ | compiled (C) → now **pre-built** |
| `zstandard` 0.25 | ✖ | compiled (C, bundles the whole zstd source — the slowest) → now **pre-built** |
| `cffi` 2.0 | ✖ | compiled (C) → now **pre-built** |
| `pyyaml` 6.0.3 | ✖ | compiled (C) → now **pre-built** |
| `mistralai-vibe-local-harness` (2.25.1–2.25.5) | ✖, and no sdist | **impossible** (§3b) |
| `mistral-vibe` itself (2.25.7+) | ✖ (sdist needs cargo) | **refused** (§3b) |

Since 2026-08-10 the five C wheels come pre-built from
[smartpi-wheels](https://github.com/Yumi-Lab/smartpi-wheels) (built once on real
hardware, `UV_FIND_LINKS` in `lib/vibe-release.sh`): the 2026-10-12 cold install
compiled nothing. The apt build deps below stay as the fallback for a new
upstream pin that lands before it is pre-built.

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

## 3b. The 2.25.1 wall: a native harness with no armv7l build

On 2026-10-12 the published `install.sh` **failed on every fresh pad**: Mistral had
moved part of Vibe to Rust, and nothing in that part exists for armv7l.

| Vibe | Wheel | Native part | On armv7l |
|---|---|---|---|
| ≤ 2.25.0 | `py3-none-any` | none | ✔ installs |
| 2.25.1–2.25.5 | `py3-none-any` | `mistralai-vibe-local-harness` (pyo3): wheels for x86_64 / aarch64 / macOS / Windows only, **no sdist** | ✖ unsatisfiable |
| 2.25.7+ | `cp312-abi3` per platform, same four | harness + a Rust TUI bundled in the wheel; sdist builds with maturin and **needs cargo** (~360 + ~480 crates) | ✖ build fails |

The harness is not optional — `vibe/cli/cli.py` and `entrypoint.py` import it (only
the Rust TUI is: `VIBE_CLI=python`). 2.25.5 also adds `miniaudio` (C, no armv7l
wheel; its build probes for `c++`). Measured on the pad:

- unconstrained `uv tool install mistral-vibe` → resolves 2.26.1, builds `miniaudio`
  (fails without g++: `No such file or directory: 'c++'`), then fails building
  `mistral-vibe` itself: `Building Vibe from source requires the Rust toolchain,
  but cargo was not found`;
- pinning `mistral-vibe==2.25.5` → `mistralai-vibe-local-harness==0.5.1 has no
  wheels with a matching platform tag (manylinux_2_41_armv7l)`.

The fix is one uv rule, not a version number: **never build `mistral-vibe` from
source** (`UV_NO_BUILD_PACKAGE=mistral-vibe`). Releases without a usable wheel
then become incompatible and uv's resolver backtracks on its own, past the
harness-only ones, to **2.25.0** (installed in 7 min, nothing compiled). uv stores
the rule (and the wheel index) in the tool receipt, so later upgrades — even a
bare `uv tool upgrade` — keep it, and the moment an armv7l wheel exists (upstream
or in smartpi-wheels) uv takes it. The update probe asks the same question as a
dry run (`uv pip install --dry-run --only-binary mistral-vibe`, 3 s), so the
gateway badge reports the installable version, not PyPI's.

Getting past 2.25.0 means building the 2.25.7+ wheel for armv7l elsewhere (cross-
compiling the Rust part with maturin) and publishing it to smartpi-wheels — the
rule above then picks it up with no change here.

## 4. Thermals: two core knobs (build + runtime)

The single real hazard is heat. Both the wheel compile *and* a heavy agent loop
can pin all four cores, and a sustained 4-core load on the passively-cooled H3 is
exactly the workload that **drove this same pad to 102 °C and froze it** (measured
incident, documented in the grok methodology). So — matching `KIMI_BUILD_CPUS` /
`KIMI_CPUS` on kimi-cli-smartpi and `GROK_CPUS` on grok-cli-smartpi — this repo
exposes two `taskset -c … nice -n 5` knobs, **both defaulting to all 4 cores**
(fast; the Yumi build bench adds a fan). On a **fanless** board, drop them.

**`VIBE_BUILD_CPUS`** — the one-off wheel compile (today only the fallback when a
wheel is missing from smartpi-wheels; the measurements below date from when five
wheels still compiled on-board). The installer wraps the whole
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
~/.local/bin/vibe-check-update                      update probe, one JSON line (this repo)
~/.local/share/vibe-cli-smartpi/vibe-release.sh     wheel index + no-build rule (this repo, §3b)
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

Measured on the SmartPad (2.21.0, July). Re-measured on 2.25.0 (2026-10-12):
`vibe --version` **0.56 s** (the new launcher answers it without importing the
CLI), one-shot up to Mistral's reply (invalid key) **23.1 s wall / 19.5 s user** —
the board-bound profile below still holds.

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

## 9. Dead ends (tested)

Vibe is the smoothest of the four (native, no emulation, no version pin), so the
list is short — but these were tried on the H3 and rejected:

- **The native browser sign-in on a headless pad** — `vibe --setup` → *Sign in with
  browser* calls `webbrowser.open()` on the **local** machine and raises when there
  is no browser / `$DISPLAY`. Dead end on a headless H3; replaced by the
  `vibe-signin` helper that prints the URL to approve on another machine (§6a).
- **Assuming Vibe is a thin client** — the ~20 s one-shot is **board-bound, not
  API-bound**: ~17 s is the Cortex-A7 running the Python client (cold start +
  agent-loop init), not the Mistral round-trip (§8). Batch scripts that budget for
  "just network latency" are wrong by ~17 s per call — keep an interactive session
  open instead.
- **Bracing for the armhf Rust build** — the usual killer (compiling
  `cryptography`'s Rust backend on 1 GB of RAM) **never happens**: `cryptography`
  and `pydantic-core` ship armv7l wheels, so only small C extensions compile (§3).
  Don't waste time provisioning a Rust toolchain.
- **Blind reinstalls** — re-running the official `uv tool install` / installer over
  an existing setup rewrites `~/.local/bin/vibe` back to the bare symlink,
  dropping the `VIBE_CPUS` wrapper. Use `install.sh` instead (idempotent, and the
  updater) — see Maintenance below.
- **Installing g++ so 2.25.5+ builds** — gets `miniaudio` through (~4 min of
  single-threaded `cc1`), only to stop on the Rust harness right after (§3b).
- **Pinning the last `py3-none-any` wheel (2.25.5)** — the wheel is pure Python but
  depends on the native harness package, which has no armv7l wheel and no sdist.
- **Compiling Vibe 2.25.7+ on the board** — maturin + cargo over ~840 crates on a
  1 GB Cortex-A7: not attempted, cross-compiling elsewhere is the only sane path.
- **`uv pip compile` as the update probe** — it resolves on metadata only and
  answers 2.26.1 (not installable). `uv pip install --dry-run --only-binary`
  checks the platform tags and answers 2.25.0.

## 10. Maintenance

- **Upgrading**: re-run `install.sh` — already installed → `uv tool upgrade
  mistral-vibe` under the §3b rule (6 s when current; measured 2.24.5 → 2.25.0 on a
  pad installed before the rule, whose receipt uv then rewrote), then the wrapper,
  helpers and PATH lines are restored. `VIBE_FORCE=1` re-runs the full official
  installer (repair).
- **Checking**: `vibe-check-update` (one JSON line, the gateway's probe).
- **`taskset` is only about heat**: it matters for the compile fallback; the
  defaults already use all 4 cores (fan bench).
- Check thermal health after heavy use:
  `cat /sys/class/thermal/thermal_zone0/temp`.

## 11. Network: mainland China

Measured 2026-10-12 from a Smart Pi One on a direct Hangzhou fibre line (no VPN):

| Endpoint | Used for | Result |
|---|---|---|
| `raw.githubusercontent.com` | this installer, wheel index | ✔ 0.5–1.2 s |
| `astral.sh` | uv installer script | ✔ 5 s |
| `github.com/…/releases/download` | uv binary, smartpi-wheels assets | ✖ ~5 KB/s, times out |
| `pypi.org` / `files.pythonhosted.org` | Vibe and its dependencies | ✔ |
| `mistral.ai` | official Vibe installer | ✖ connection refused |
| `api.mistral.ai`, `console.mistral.ai` | every prompt, sign-in | ✖ DNS-poisoned, unreachable |

The local resolver answers `*.mistral.ai` with unrelated addresses, so sending the
traffic through a tunnel is not enough on its own — DNS has to be resolved through
it too. From the same office on a VPN exit outside China with its resolver,
`api.mistral.ai` answers normally. A pad in China therefore needs that kind of
network for both the install and every prompt.

