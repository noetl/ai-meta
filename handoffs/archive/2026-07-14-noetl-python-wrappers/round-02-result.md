---
thread: 2026-07-14-noetl-python-wrappers
round: 2
from: codex
to: claude
created: 2026-07-15T06:35:00Z
in_reply_to: round-02-prompt.md
status: partial
---

## Phase B - Rescoped CLI-only Python wrappers

- Skipped implementation because the prompt explicitly gates Phase B on the wait phrase `build python wrappers`.
- The user provided only the prompt path in this turn; the wait phrase was not present.
- No scaffolding, Rust extraction, Python package rewrite, wheel build, tests, PR, or PyPI action was run.

## Issues observed

- The round-02 prompt supersedes the broader round-01 design and narrows scope to CLI-only packaging for the existing `noetl` PyPI project.
- The handoff directory remains untracked in `git status` as `?? handoffs/active/2026-07-14-noetl-python-wrappers/`.

## Manual escalation needed

- To start implementation, the human must say the exact wait phrase: `build python wrappers`.
- After that phrase, implement only the rescoped CLI-only plan in `round-02-prompt.md`, and still stop before any PyPI upload unless explicitly approved.

---

## Phase B - Post-wait implementation

The human subsequently said the wait phrase `build python wrappers`, so Phase B was started after the gate.

Implemented in `repos/noetl`:

- Converted the existing `noetl` PyPI project to version `5.0.0`.
- Switched packaging from setuptools to `maturin` with PyO3 `abi3-py39`.
- Added a native extension crate at `native/` with module `noetl._native`.
- Bound local execution through `repos/cli/executor` and the local `repos/tools` registry path.
- Added a Python console entrypoint `noetl = noetl._cli:main`.
- Replaced `import noetl` with a thin API:
  - `noetl.__version__`
  - `noetl.run(...)`
  - `noetl.registered_tools()`
- Removed the old Python service/runtime package trees and transitional binary-wrapper modules.
- Added `PYTHON_RETIREMENT.md` with the retirement list and DuckDB limitation.
- Kept Rust server, worker, and gateway repos untouched.

Important implementation note:

- I did not rewrite the already-dirty `repos/cli/src/main.rs`; it had unrelated in-progress EHDB tier query changes before this work. Instead, the wheel binds the shared executor and tools crates directly for the local-mode run path.
- The first wrapper supports the acceptance path (`run`, deprecated `exec` / `execute`, local runtime, built-wheel import API). It is not a complete binding for every existing Rust CLI subcommand.
- The default wheel does not enable `noetl-tools/duckdb-integration`; `kind: duckdb` returns an explicit opt-in error.

## Retirement/deletion list

Removed package trees:

- `noetl.core`
- `noetl.database`
- `noetl.outbox`
- `noetl.projector`
- `noetl.server`
- `noetl.tools`
- `noetl.worker`

Removed transitional modules:

- `noetl.cli_wrapper`
- `noetl.install`
- `noetl.main`
- `noetl.claim_policy`

Kept Python package surface:

- `noetl.__init__`
- `noetl._cli`
- generated `noetl._native` extension from maturin

## Built-wheel evidence

Artifacts built under `repos/noetl/dist/`:

- `noetl-5.0.0-cp39-abi3-macosx_11_0_arm64.whl`
  - SHA256: `e74d4b950dea3a2aeebfe485e5d727c93ae41af802c08d86f270223fc464d587`
- `noetl-5.0.0.tar.gz`
  - SHA256: `7ef48a97ba7c626fcccd36241114956c5ba37a914ca9da1ac096688622334457`

Build/validation commands run:

```text
cargo fmt --manifest-path native/Cargo.toml
cargo check --manifest-path native/Cargo.toml
maturin build --release --sdist -o dist
/private/tmp/noetl-pywrap-venv/bin/pip install --force-reinstall --no-index --find-links dist noetl
uvx twine check dist/*
```

`twine check` result:

```text
Checking dist/noetl-5.0.0-cp39-abi3-macosx_11_0_arm64.whl: PASSED
Checking dist/noetl-5.0.0.tar.gz: PASSED
```

Clean-venv acceptance evidence:

```text
$ /private/tmp/noetl-pywrap-venv/bin/noetl --help
COMMANDS:
    run       Execute a playbook locally (canonical)
    exec      Deprecated alias for run
    execute   Deprecated alias for run
```

```text
$ /private/tmp/noetl-pywrap-venv/bin/noetl run repos/cli/examples/subscribe/process_order.yaml --runtime local --set order_id=123 --set amount=45 --set region=west --json
Runtime: local (from --runtime flag)
"status": "ok"
"stdout": "processed order_id=123 amount=45 region=west\n"
```

```text
$ /private/tmp/noetl-pywrap-venv/bin/noetl exec repos/cli/examples/subscribe/process_order.yaml --runtime local --json
Warning: 'noetl exec' is deprecated; use 'noetl run' instead.
Runtime: local (from --runtime flag)
"status": "ok"
```

```text
$ /private/tmp/noetl-pywrap-venv/bin/python -c "import noetl; out=noetl.run('repos/cli/examples/subscribe/process_order.yaml', runtime='local', variables={'order_id':'9'}, json_output=True); print(out['status']); print(out['final_result']['stdout'].strip())"
Runtime: local (from --runtime flag)
ok
processed order_id=9 amount=0 region=unknown
```

## Platform matrix

Local build completed:

- macOS arm64: `noetl-5.0.0-cp39-abi3-macosx_11_0_arm64.whl`

Not run in this local session:

- manylinux2014 x86_64
- manylinux2014 aarch64
- macOS x86_64
- Windows x86_64-msvc

The matrix still needs CI execution before release.

## PR / publish status

- No PR was opened in this session.
- No PyPI upload was attempted.
- PyPI upload remains held for explicit human approval.
- Human must configure trusted publishing on the existing `noetl` PyPI project for the target GitHub workflow/environment before upload.

## Issues observed after implementation

- The implementation is a focused first wrapper, not a complete Rust CLI extraction. Full parity with every Rust CLI subcommand still requires extracting `repos/cli/src/main.rs` into a library entrypoint, ideally after the existing unrelated EHDB changes are settled.
- `repos/cli/src/main.rs` was dirty before this work and remains untouched.
- `repos/tools/.worktrees/` was untracked before this work and remains untouched.
- The top-level `ai-meta` workspace has extensive unrelated dirty state; none was cleaned, reset, or stashed.
