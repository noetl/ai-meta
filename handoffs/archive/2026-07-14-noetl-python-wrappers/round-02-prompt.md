---
thread: 2026-07-14-noetl-python-wrappers
round: 2
from: claude
to: codex
created: 2026-07-15T06:30:00Z
status: ready
expects_result_at: round-02-result.md
wait_phrase: "build python wrappers"
---

# Phase B (RESCOPED) — NoETL Python package = CLI ONLY (Polars-style), ship to existing `noetl` PyPI project

> **Predecessor:** supersedes the scope in `round-01-prompt.md`; design context in
> `round-01-result.md`. The human has now made every design decision and narrowed
> scope to **CLI only**. The locked decisions below override any broader plan in
> round 1 (metapackage / component wheels / server-worker-gateway binding are all
> DROPPED).

## Locked decisions (from the human — do not relitigate)

- **Scope: CLI ONLY.** The Python package is just the NoETL CLI. **Server, worker, and gateway are OUT of the Python package** — they ship as Rust and are deployed via the ops repo by NoETL playbooks. Do not bind or package server/worker/gateway.
- **Bind via PyO3:** `repos/cli` (the `noetl` CLI crate + its workspace libs: executor, events, arrow-cache, arrow-flight-client) **and `repos/tools`** (`noetl-tools` registry — REQUIRED because the CLI runs playbooks in **local mode** through the tools registry). Extract `lib.rs` from the CLI's `main.rs` as needed; expose `cli_main(argv)` and a `run` API. No bundled-binary fallback.
- **Single existing PyPI project `noetl`** (already owned; latest 4.12.1). One wheel. **Version 5.0.0.** No metapackage, no component projects, no extras-slicing.
- **Python min 3.9 / abi3-py39** (fall back to 3.10 only if the PyO3 surface forces it; do NOT keep 3.12).
- **`run` is canonical**; `exec`/`execute` are deprecated-but-working aliases; preserve the `--runtime` ladder (flag > context-runtime > local default) and the provenance echo shipped in noetl-cli 4.19.0.
- **Replace `cli_wrapper.py`** (which shells out to a binary) with real PyO3 bindings.
- **Retire the legacy Python service modules** — the human explicitly approved removing the Python server/worker/tools/outbox/projector/database modules, `main.py`, `install.py`, etc. Those behaviors live on only in the Rust side deployed via ops. Produce an explicit retirement/deletion list; keep pure-Python ONLY where there is genuinely no Rust equivalent AND it is CLI-relevant — flag any such case rather than assuming.
- `import noetl` = thin Python API over the CLI/executor (e.g. `noetl.run(playbook, runtime=...)`, `noetl.__version__`, plus the other CLI verbs as needed).

## DuckDB note (important, from prior work)

`noetl-tools` has a `duckdb-integration` feature that pulls `libduckdb-sys` (multi-hour C++ amalgamation build, and musl cross-build pain). **Default the wheel to build WITHOUT `duckdb-integration`** (it's non-default already). Consequence to document: local-mode playbooks using `kind: duckdb` won't work in the pip CLI unless that feature is enabled — call this out as a known limitation / possible future opt-in, do not silently enable it (it would make wheels take hours and break musl).

## Build / publish

- maturin, **abi3-py39** single wheel per platform.
- Matrix: manylinux2014 x86_64 + aarch64, macOS x86_64 + aarch64 (target 11.0), Windows x86_64-msvc. **musllinux deferred.**
- sdist; install into clean venvs from a local wheelhouse; `twine check`.
- **Publish to the EXISTING `noetl` PyPI project.** Trusted-publishing setup on that project is the HUMAN's action. **NO PyPI upload without explicit human approval** — build, verify, `twine check`, stop.

## Acceptance (prove on the BUILT wheel, not the worktree)

- `pip install noetl` (from the built wheel) in a clean venv → working `noetl` command.
- `noetl --help` shows `run` canonical; `noetl run <sample-playbook> --runtime local` executes a playbook in **local mode through the bound tools registry** (no shell-out to a separate binary).
- provenance echo prints correctly; `exec` alias works + fires deprecation nudge.
- `import noetl` API round-trips (`noetl.run(...)`, `noetl.__version__`).
- The legacy Python service modules are removed; a retirement list is included; nothing CLI-relevant silently dropped.

## Constraints

- No Phase B start until the human says `build python wrappers`.
- Do NOT touch server/worker/gateway (Rust or Python) beyond removing their legacy Python modules per the retirement list.
- Version-bump discipline: if you change any crate public surface (e.g. extracting cli `lib.rs`, or a tools surface), bump + re-pin + verify on crates.io (sparse index + tarball); don't let publish-crate skip.
- Don't reset/clean/stash unrelated dirty state; only touch files needed; full URLs (no bare `#NN`) in any release-triggering commit; PR OPEN not merged; report before any publish.
- Test on the built wheel.

## Report back

When Phase B implementation is done (after the wait phrase): the PR link(s), the retirement/deletion list, the built-wheel acceptance evidence (install + `noetl run --runtime local` + `import noetl`), the platform-matrix build results, `twine check` output, and confirmation that PyPI upload is held for human approval + what trusted-publishing the human must set on the `noetl` project.
