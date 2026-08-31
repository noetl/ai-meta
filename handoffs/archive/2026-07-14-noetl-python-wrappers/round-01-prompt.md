---
thread: 2026-07-14-noetl-python-wrappers
round: 1
from: codex
to: codex
created: 2026-07-15T06:00:55Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "build python wrappers"
---

# Codex Task — NoETL Python wrapper packages over the Rust ecosystem (Polars-style, single `pip install noetl`)

## Objective

Turn the NoETL Rust ecosystem into a **single PyPI presence `noetl`** that Python users install with `pip install noetl` (and role extras like `pip install noetl[worker]`) and use exactly like [Polars](https://pola.rs) — a thin Python API over compiled Rust, plus a **single `noetl` command-line entry point** that dispatches to every NoETL service (cli, gateway, server, worker) and any other Rust module.

Replace the existing Python implementation code in `repos/noetl/noetl` with **Python API wrappers** that call into the Rust code via native bindings (PyO3), so the Python package is an interface to the Rust engine rather than a parallel implementation.

End state the user experiences:

```bash
pip install noetl[all]     # or noetl[cli] / noetl[worker] / noetl[server] / noetl[gateway]
noetl --help               # single command
noetl run <playbook>       # cli
noetl server               # start the server (if server component installed)
noetl worker               # start a worker
noetl gateway              # start the gateway
```
```python
import noetl                # Python API over the Rust core
```

## Reference model (study first)

Polars ships a Rust core with Python bindings built by **maturin + PyO3**, published to PyPI as one package (`pip install polars` / `import polars`), using **abi3** wheels so one wheel works across Python versions. Read: maturin.rs (bindings, distribution, `[tool.maturin]`, `[project.scripts]`); pyo3.rs building-and-distribution (abi3, `extension-module`); pola-rs/polars `py-polars` layout; and maturin issue #368 (ship lib + CLI via `[project.scripts]` entry functions rather than bundled binaries, which double wheel size).

## Repository context

- Work in `repos/noetl/noetl`. Rust modules: **cli, server, worker, gateway** (+ any other ecosystem crates).
- Existing Python code must be **replaced by wrappers** — no two implementations of the same logic; Python becomes the binding layer only.
- Follow repo rules (`AGENTS.md`, `agents/rules/execution-model.md`) and the handoffs convention (`handoffs/README.md`).

## PHASE A — INSPECT & DESIGN ONLY (no publishing, no PyPI, no destructive rewrites)

1. **Crate inventory & shape.** For cli/server/worker/gateway (+others): bin, lib, or both? Public surface? Which are long-running services vs one-shot commands? This drives the binding strategy.
2. **Binding strategy (core question), per module:** (a) PyO3 library bindings (Polars-style) — refactor each module to lib + thin main, expose callable entries (`serve()`, `run_worker()`, `run_gateway()`, `cli_main(argv)`) from one PyO3 extension module; console scripts and the Python API both call in. Preferred — gives a real Python API. (b) Bundled binaries — ship compiled binaries and shell out; use only where (a) is impractical. Long-running tokio services via PyO3 need a clear runtime start/stop + signal-handling story — address it. Recommend per module and justify.
3. **Single-entry-point design.** One `noetl` command, subcommands run/server/worker/gateway/… . Show `pyproject.toml` `[project.scripts]` + `[tool.maturin]` for exactly one entry point. `import noetl` exposes a coherent API. Preserve the CLI's **`run`-canonical verb + `--runtime` flag > context-runtime > local-default** ladder (just shipped in noetl 4.19.0).
3b. **Extras / install-slicing — REQUIRED fork to decide + recommend.** User wants `noetl[cli]`/`noetl[worker]`/`noetl[server]`/`noetl[gateway]`/`noetl[all]` extras that ACTUALLY slice the install (components deploy to different machines; a worker node must not download the server binary). Extras only slice if components are separate wheels. Evaluate: (i) **Metapackage + component wheels (recommended for a distributed system):** thin `noetl` metapackage whose extras depend on separately-built `noetl-cli`/`noetl-server`/`noetl-worker`/`noetl-gateway` wheels; `pip install noetl[worker]` pulls only the worker; the single `noetl` command dispatches to whatever components are installed (`noetl worker` runs if present, else prints `pip install noetl[worker]`). Preserves one command + one install name AND real per-role slicing. (ii) **Monolith wheel (Polars-style):** one compiled extension has everything; extras gate only optional Python-side deps, not Rust code; can't slim by role. Recommend (i) unless strong reason otherwise; show the `[project.optional-dependencies]` extras table and the command's discover/dispatch mechanism; state what bare `pip install noetl` gives (== `noetl[all]` or a minimal core).
4. **Python-replacement map.** Each existing Python module → its wrapper + the Rust surface it binds. Flag anything with no Rust equivalent — don't silently drop behavior.
5. **Build & distribution plan.** maturin; abi3 wheel (min e.g. 3.9); platform matrix (manylinux x86_64 + aarch64, macOS arm64 + x86_64, Windows x86_64) via maturin-action/cibuildwheel; sdist; mapping to https://pypi.org/project/noetl/; note whether the `noetl` PyPI name is owned/claimable and what trusted-publishing setup the human must do.
6. **Versioning.** How the Python/metapackage version relates to the crate versions (cli/server/worker/gateway are separately versioned on crates.io). Recommend a unified `noetl` version and how it pins the crate/component versions.
7. **Risks:** tokio-in-PyO3, binary size, cross-compilation (aarch64/musl), replacing Python without regressions, import-break/migration notes.

Write the Phase A design to a NEW handoff result file under handoffs/active/<this dir>/ (do not clobber). Report and STOP.

## PHASE B — IMPLEMENT (only after the human says the wait phrase: `build python wrappers`)

1. Scaffold maturin/PyO3 (`py-noetl` crate or equivalent), pyproject.toml with `[tool.maturin]` + `[project.scripts] noetl = …`, abi3 feature, `noetl` package dir, and the extras/component structure from the design.
2. Refactor targeted Rust modules to lib + thin-main; expose PyO3 entry functions from one extension module (per component under the metapackage model).
3. Implement the single `noetl` CLI dispatcher (run/server/worker/gateway/…) with installed-component discovery, and the `import noetl` API wrappers. Preserve the `run`-canonical / `--runtime` ladder.
4. Replace existing Python implementation with wrappers per the map; keep public Python API stable where possible; document breaks.
5. CI: build wheels across the matrix + sdist; test on the BUILT wheels in a clean venv (not the worktree): `noetl --help`, `noetl run <sample>`, start server/worker/gateway, `import noetl` round-trips, and each extra installs only its component.
6. **Do NOT publish to PyPI without explicit human approval.** Build + verify wheels; `twine check`; stop before upload. PyPI credentials / trusted publishing are the human's to configure.

## Hard constraints

- Phased: no Phase B until the wait phrase. No PyPI upload without explicit approval.
- **One `noetl` command, one install name `noetl`** — not four user-facing commands. Extras must actually slice the install (worker node ≠ server binary).
- Preserve the CLI's `run`-canonical + `--runtime` (flag > context > local-default) behavior in the Python entry.
- No duplicate implementations: Python becomes wrappers over Rust.
- Respect repo rules; don't reset/clean/stash unrelated dirty state; only touch files needed; follow handoffs convention; use full URLs (no bare `#NN`) in any release-triggering commit body.
- Test on the BUILT wheel, not just cargo/worktree.

## Acceptance criteria

- `pip install noetl[all]` (from built wheels) in a clean venv → working `noetl` command with run/server/worker/gateway and a usable `import noetl` API; role extras install only their component.
- Wheels build across the agreed matrix (abi3, one wheel per platform across Python versions).
- Existing NoETL Python behavior served by wrappers over Rust, no parallel Python implementation left (or documented exceptions).
- Ready-to-publish artifacts + clean `twine check`; upload gated on human approval.

## Report back

Phase A complete: design doc path, per-module binding decision, the extras/metapackage recommendation with the `[project.optional-dependencies]` table, single-entry-point `pyproject.toml` sketch, Python-replacement map, build/matrix/PyPI plan, versioning, and the forks needing the human's decision (esp. what bare `pip install noetl` installs). Then wait for `build python wrappers`.
