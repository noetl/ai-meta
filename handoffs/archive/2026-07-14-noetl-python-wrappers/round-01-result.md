---
thread: 2026-07-14-noetl-python-wrappers
round: 1
from: codex
to: claude
created: 2026-07-15T06:00:55Z
in_reply_to: round-01-prompt.md
status: complete
---

# Phase A Design: NoETL Python Wrappers Over Rust

Phase A only was performed. I inspected the local repo state read-only, checked the packaging references, wrote this design, and stopped. No Phase B scaffolding, no PyPI publishing, and no Rust/Python implementation files were changed.

## Phase A - Inspect And Design

### 1. Crate inventory and runtime shape

Current active Rust surface is split across submodules, not inside `repos/noetl/noetl`:

| Component | Local path | Package/crate | Shape observed | Runtime class | Binding implication |
|---|---|---:|---|---|---|
| CLI | `repos/cli` | `noetl` v4.12.0 | binary-first root crate, `[[bin]] noetl` and `[[bin]] ntl`; workspace members `noetl-executor`, `noetl-events`, `noetl-arrow-cache`, `noetl-arrow-flight-client` | mostly one-shot commands; `subscribe` is long-running | needs extraction of `src/main.rs` into a library entry before PyO3 |
| Server/control plane | `repos/server` | `noetl-server` v3.53.1 | has `src/lib.rs` and `[[bin]] noetl-control-plane`; most router/startup wiring still in `src/main.rs` | long-running Axum/Tokio service | good PyO3 candidate after moving startup/router builder into lib |
| Worker | `repos/worker` | `noetl-worker` v5.72.0 | has `src/lib.rs` and `[[bin]] noetl-worker`; exports `WorkerConfig`, `SubscriptionRuntime`, `Worker` | long-running command worker or subscription runtime | best current PyO3 candidate; needs a public `run_worker` wrapper with shutdown handle |
| Gateway | `repos/gateway` | `noetl-gateway` v3.2.0 | binary-first, modules are private under `src/main.rs`; no explicit `[[bin]]` entry, so Cargo default binary applies | long-running Axum/GraphQL edge service | needs lib extraction first; PyO3 is feasible but not immediate |
| Tool engine | `repos/tools` | `noetl-tools` v3.21.0 | library crate with registry, tool config/result, template, auth, Arrow codec, source/spool | in-process tool calls | expose selected library APIs through worker/CLI component bindings, not as a top-level service command |
| Shared executor | `repos/cli/executor` | `noetl-executor` v0.5.0 | library crate shared by CLI local runner and worker | one-shot block execution primitives | bind indirectly through CLI/worker APIs; direct advanced module optional |
| Event envelope | `repos/cli/events` | `noetl-events` v0.1.0 | library crate for `ExecutorEvent` and `EventSink` | data model | bind as Python dataclasses/converters if needed |
| Arrow IPC cache/client | `repos/cli/arrow-cache`, `repos/cli/arrow-flight-client` | v0.1.0 / v0.5.0 | library crates | data plane helpers | bind as optional data-plane API; required by worker package |
| Doctor | `repos/doctor` | `noetl-doctor` v0.1.0 | binary-only helper | one-shot / MCP repair helper | leave out of first `noetl` extras unless explicitly added as `noetl[doctor]` later |
| EHDB | `repos/ehdb` | multiple `ehdb-*` crates | Rust workspace with core/reference/storage/service/etc. | storage/reference subsystems | bind only where server/worker already consume it; do not create direct Python data-touch shortcuts |

Important local findings:

- `repos/noetl/pyproject.toml` currently declares Python package `noetl` v4.24.0, Python `>=3.12`, and setuptools build, with no `[project.scripts]`. It has extras `dev`, `publish`, `notebook`, `ibkr`, but no `cli`, `worker`, `server`, or `gateway`.
- `repos/noetl/noetl/main.py` is a retired command entry point that exits with guidance to install the Rust CLI.
- `repos/noetl/noetl/cli_wrapper.py` shells out to a `noetl` binary found on `PATH` or in `noetl/bin/noetl`. This is the bundled-binary pattern the new design should replace.
- The CLI already preserves the key runtime ladder in `repos/cli/src/main.rs`: `resolve_runtime` checks explicit `--runtime`, then context runtime, then auto/local fallback. The `Commands::Exec` command has `alias = "run"`, but the requested API should present `run` as canonical and keep `exec`/`execute` as compatibility aliases.

### 2. Binding strategy by module

Recommendation: use PyO3 library bindings for all primary components after minimal lib extraction; do not use bundled binaries as the target architecture.

| Module | Decision | Why | Required Rust refactor before binding |
|---|---|---|---|
| CLI / `run` | PyO3 | It is mostly one-shot command logic, and Python API users need real calls such as `noetl.run(...)`, not a subprocess. Shelling out would preserve today's transitional wrapper but duplicate CLI parsing and complicate JSON/error handling. | Split `repos/cli/src/main.rs` into `src/lib.rs` plus thin `main.rs`; expose `pub async fn cli_main(argv: Vec<String>) -> Result<i32>`, `pub async fn run_playbook(opts)`, and context helpers. Keep Rust binary behavior unchanged. |
| Server | PyO3 | Long-running service can still be started from Python if the Rust runtime owns the Axum server. This gives `noetl server` and `noetl.server.serve(...)` without shipping a second binary. | Move `init_tracing`, `build_router`, config loading, pool setup, background task spawning, TLS/listener startup, and shutdown handling from `main.rs` into a public `serve(ServerOptions, ShutdownToken)` function. Keep `noetl-control-plane` as thin caller. |
| Worker | PyO3 | Already library-backed. It exposes `Worker`, `WorkerConfig`, and `SubscriptionRuntime`, so it is the cleanest component to bind. | Add a public async `run_worker(WorkerOptions, ShutdownToken)` that wraps the current `main.rs` mode selection (`WORKER_MODE=subscription` vs command) and signal behavior. |
| Gateway | PyO3 after lib extraction | Gateway is a gatekeeper process; Python should only start/configure it, not add data access. Bundling a binary would be easier but less useful for `import noetl.gateway`. | Move private modules out from `main.rs` into `lib.rs`; expose `serve_gateway(GatewayOptions, ShutdownToken)`. Keep database usage limited to current gateway behavior and respect "gateway = gatekeeper" boundaries. |
| Tools / executor / events / locator / Arrow | PyO3 as supporting APIs, not direct commands | These crates are library-first and define models/tool dispatch. Expose data models and helper functions where Python callers need compatibility. Do not expose shortcuts that bypass playbook policy. | Add focused wrappers: event envelope conversion, resource locator parse/build, tool registry metadata, Arrow IPC helper APIs. Avoid broad direct database/tool execution APIs in the top-level Python package. |
| Doctor / EHDB direct binaries | Not in first wrapper scope | Useful, but not requested for the first single-command role set. EHDB is already consumed by server/worker; direct Python access risks violating the platform boundary. | Consider `noetl[doctor]` and advanced `noetl.ehdb` later only with explicit policy. |

Long-running Tokio services via PyO3:

- Each component extension owns one Tokio multi-thread runtime or uses `pyo3-async-runtimes` consistently; do not nest ad-hoc `#[tokio::main]` functions under Python.
- Python APIs should return a small handle for services (`ServerHandle`, `WorkerHandle`, `GatewayHandle`) with `stop()`/`join()` methods. Console-script calls block until SIGINT/SIGTERM and translate exits to POSIX exit codes.
- Rust owns signal handling for console mode; Python API mode uses explicit cancellation tokens so notebooks/tests do not install process-global signal hooks.
- The GIL must be released around blocking service loops.

Bundled binaries should be a temporary escape hatch only for a component that cannot be lib-extracted in one Phase B slice. If used temporarily, hide it behind the same dispatcher and mark it as debt; do not make it the target because it doubles artifacts and prevents a useful Python API. Maturin issue 368 documents the limitation that `-b bin` builds binaries while `-b pyo3` builds a library, so shipping both as first-class wheel outputs is not the clean path.

### 3. Packaging and extras model

Recommendation: metapackage plus component wheels.

Bare `pip install noetl` should install a small pure-Python metapackage/dispatcher and client-side wrapper API only. It should not install server, worker, gateway, or heavy tool graphs. This is the only default that preserves real role slicing: a worker node should not download the server/gateway artifacts by accident.

User-facing installs:

```bash
pip install noetl              # dispatcher + client API, no native role component
pip install noetl[cli]         # adds local/distributed run capability
pip install noetl[worker]      # worker node, no server/gateway wheel
pip install noetl[server]      # control-plane server
pip install noetl[gateway]     # edge gateway
pip install noetl[all]         # workstation/dev/full image
```

Technical PyPI projects:

- `noetl`: pure Python metapackage and dispatcher, owns the `noetl` console script.
- `noetl-cli`: native PyO3 wheel exposing `noetl_cli._native`.
- `noetl-worker`: native PyO3 wheel exposing `noetl_worker._native`.
- `noetl-server`: native PyO3 wheel exposing `noetl_server._native`.
- `noetl-gateway`: native PyO3 wheel exposing `noetl_gateway._native`.

This still preserves the single install name in user docs because users install `noetl[...]`. The backing component packages are implementation details, similar to current Polars runtime wheels: the raw Polars metadata now uses package `polars` with a runtime dependency such as `polars-runtime-32 == <version>` and optional runtime extras.

Metapackage `pyproject.toml` sketch:

```toml
[build-system]
requires = ["setuptools>=69", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "noetl"
version = "5.0.0"
description = "NoETL Python API and single command dispatcher over Rust components"
requires-python = ">=3.9"
dependencies = [
  "typing-extensions>=4.9; python_version < '3.11'",
]

[project.scripts]
noetl = "noetl._dispatch:main"

[project.optional-dependencies]
cli = ["noetl-cli == 5.0.0"]
worker = ["noetl-worker == 5.0.0"]
server = ["noetl-server == 5.0.0"]
gateway = ["noetl-gateway == 5.0.0"]
tools = ["noetl-tools-runtime == 5.0.0"]  # optional only if split separately later
all = [
  "noetl-cli == 5.0.0",
  "noetl-worker == 5.0.0",
  "noetl-server == 5.0.0",
  "noetl-gateway == 5.0.0",
]
dev = ["pytest>=8", "maturin>=1,<2", "twine>=6"]
```

Component `pyproject.toml` sketch, repeated per native package:

```toml
[build-system]
requires = ["maturin>=1,<2"]
build-backend = "maturin"

[project]
name = "noetl-worker"
version = "5.0.0"
requires-python = ">=3.9"
dependencies = ["noetl == 5.0.0"]

[tool.maturin]
bindings = "pyo3"
manifest-path = "crates/noetl-worker-py/Cargo.toml"
python-source = "python"
module-name = "noetl_worker._native"
compatibility = "pypi"
auditwheel = "repair"
strip = true
```

Single-command dispatcher:

- `noetl._dispatch:main` owns the only user-visible `noetl` console script.
- It imports component entrypoints lazily using `importlib.util.find_spec`.
- `noetl run ...` calls `noetl_cli.cli_main(["run", ...])`.
- `noetl exec ...` and `noetl execute ...` remain compatibility aliases but help text should advertise `run`.
- `noetl server`, `noetl worker`, and `noetl gateway` call the installed component if present.
- If absent, the dispatcher exits nonzero with a direct hint: `Component 'worker' is not installed. Run: pip install 'noetl[worker]'`.

### 4. Python replacement map

The current Python package has about 365 `.py` files grouped as:

- root/transitional: `__init__.py`, `main.py`, `cli_wrapper.py`, `install.py`, `claim_policy.py`
- `core/`: auth, config, DSL/parser/executor, event store, runtime, scheduler, script, secrets, storage, workflow
- `server/`: FastAPI app, API endpoints, services, middleware, recovery
- `worker/`: NATS worker, command execution, result handling, pipeline/task sequence, auth/secrets
- `tools/`: HTTP, Postgres, DuckDB/DuckLake, Snowflake, GCS, NATS, MCP, shell, Python, transfer, container, artifact
- `outbox/` and `projector/`: process entrypoints/workers
- `database/`: SQL command helpers/schema access

Replacement plan by group:

| Python surface | Replacement wrapper | Rust source to bind | Notes / gaps |
|---|---|---|---|
| `noetl.main`, `noetl.cli_wrapper`, `noetl.install` | delete/replace with `noetl._dispatch` and `noetl.cli` wrappers | `repos/cli` after lib extraction | Stop shelling to bundled binaries. Preserve only one console script. |
| `noetl.__init__` | expose stable API: `run`, `serve`, `worker`, `gateway`, `Client`, version helpers | metapackage plus installed components | Keep import cheap; no native component imported until used. |
| `noetl.claim_policy` | keep pure Python initially or bind worker/server claim policy | `repos/worker` claim path and server command claim API | Local Python file is small and pure policy. It must be tested against Rust behavior before deletion. |
| `noetl.core.resource_locator` | thin wrapper around locator parser/builders | `repos/tools/noetl-locator` | Clear Rust equivalent exists. |
| `noetl.core.dsl.*`, `core.workflow.*` | wrapper over playbook parser/executor models | `repos/cli/executor`, `repos/server/src/playbook`, `repos/tools::template` | Need parity audit: Python has parser/model modules not obviously one-for-one in Rust. Do not drop until Rust parser covers every accepted v10 shape. |
| `noetl.core.runtime.*` | wrapper/client models over runtime/server APIs | `repos/server` runtime handlers/services, `repos/cli` context config | Server owns platform DB writes; Python should call API or Rust functions that preserve server boundary. |
| `noetl.core.auth.*`, `core.secrets.*` | wrappers over keychain/secrets provider logic where platform-owned, or keep client-side normalizers | `repos/server/src/secrets`, `repos/worker/src/executor/auth_alias.rs`, `repos/tools::auth` | Some Python helpers are normalizers and may stay pure. Business credentials must stay keychain/playbook-bound. |
| `noetl.core.event_store`, `projection_store`, `payload_store`, `messaging`, `cache`, `session` | prefer client/API wrappers or Rust store adapters | server services, worker materializers, `noetl-events`, NATS helpers | Avoid direct Python DB access for NoETL-owned tables. |
| `noetl.core.storage.*` | wrapper over Arrow/result-tier data plane | `noetl-arrow-cache`, `noetl-arrow-flight-client`, server result-tier, worker result locator | Clear Rust equivalent exists for Arrow IPC/cache; verify Python GC/router behavior before removal. |
| `noetl.server.*` | replace FastAPI app and modules with `noetl.server.serve()` wrapper | `repos/server` | The Python server implementation should retire after Rust route parity is proven. |
| `noetl.worker.*` | replace NATS worker and executors with `noetl.worker.run()` wrapper | `repos/worker`, `repos/tools`, `noetl-executor` | Strong Rust equivalent exists. Python-era worker behavior must be covered by built-wheel tests. |
| `noetl.tools.*` | expose registry metadata and selected direct tool calls through PyO3 | `repos/tools` | Most tool kinds have Rust equivalents. Flag possible gaps: `ollama_bridge`, `ibkr`, some DuckDB/DuckLake cloud helper modules, and Python-specific `python` tool semantics need parity checks. |
| `noetl.outbox`, `noetl.projector` | fold into server/worker/system pool wrappers or retire | worker materializer/state builder, server event stream/outbox services | Current Python process entrypoints should not remain parallel runtimes. |
| `noetl.database.*` | remove public direct DB helper or make admin-only CLI/API wrapper | server DB migrations/services | Direct client/gateway DB touches conflict with the execution model; keep only migration/admin surfaces owned by server. |

The first Phase B implementation should include a generated parity checklist that lists every Python module and marks it as: bound to Rust, preserved pure helper, deprecated shim, or blocked/no Rust equivalent. The gaps above are too risky to silently remove.

### 5. Build, wheel, and PyPI plan

Reference points checked:

- Maturin supports `[tool.maturin]` configuration, `bindings = "pyo3"`, `python-source`, `python-packages`, `compatibility = "pypi"`, `auditwheel = "repair"`, and `strip`.
- Maturin recommends manylinux-compatible builds for PyPI and notes `maturin-action` handles manylinux when configured.
- PyO3 `abi3` wheels allow one wheel per OS/arch for all Python versions at or above the selected minimum, e.g. `abi3-py39`.
- PyPI currently has project `noetl`, latest shown as `4.12.1` released June 4, 2026, with verified maintainer `noetl`, `Requires: Python >=3.12`, and current extras `dev`, `publish`, `notebook`, `ibkr`. Therefore the name `noetl` is owned, not claimable; the human must publish from that existing project or transfer/authorize maintainers as needed.

Recommended Python minimum: `>=3.9` if PyO3 dependency surface permits; otherwise `>=3.10`. Do not keep `>=3.12` unless there is a hard reason, because abi3 value is broader installability.

Wheel matrix:

- Linux: `x86_64-unknown-linux-gnu` manylinux2014, `aarch64-unknown-linux-gnu` manylinux2014.
- macOS: `x86_64-apple-darwin`, `aarch64-apple-darwin`, deployment target 11.0 or repo-supported minimum.
- Windows: `x86_64-pc-windows-msvc`.
- Defer musllinux until a separate Alpine requirement exists; `duckdb`/native deps and Tokio service stacks raise cross-build risk.

CI/release stages:

1. Build Rust crates normally and run existing `cargo test` for each component.
2. Build component wheels with maturin, using `--release --locked --sdist --compatibility pypi`.
3. Build the pure `noetl` metapackage wheel and sdist.
4. Install from local wheelhouse into clean venvs:
   - `pip install --no-index --find-links dist 'noetl[cli]'`
   - `pip install --no-index --find-links dist 'noetl[worker]'`
   - `pip install --no-index --find-links dist 'noetl[server]'`
   - `pip install --no-index --find-links dist 'noetl[gateway]'`
   - `pip install --no-index --find-links dist 'noetl[all]'`
5. Verify role slicing:
   - `noetl worker --help` succeeds only with worker/all.
   - `noetl server --help` succeeds only with server/all.
   - `python -c 'import noetl; print(noetl.__version__)'` works for bare install.
   - Bare install gives helpful missing-component errors.
6. Verify behavior on built wheels, not worktree:
   - `noetl --help`
   - `noetl run <sample> --runtime local`
   - `noetl run <catalog-ref> --runtime distributed` against a test server
   - start/stop server, worker, gateway in smoke mode with bounded timeouts
   - `twine check dist/*`
7. Publish only after explicit human approval.

Trusted publishing:

- For existing `noetl`, a PyPI project maintainer must add a trusted publisher for the release workflow.
- PyPI's GitHub Actions trusted publisher setup requires owner, repo, workflow filename, and optionally an environment. Use an environment such as `pypi` with manual approval.
- Repeat trusted publisher setup for `noetl-cli`, `noetl-worker`, `noetl-server`, and `noetl-gateway` if those project names are created.

### 6. Versioning recommendation

Use one unified Python distribution version across the metapackage and all component wheels, e.g. `noetl==5.0.0`, `noetl-cli==5.0.0`, `noetl-worker==5.0.0`, `noetl-server==5.0.0`, `noetl-gateway==5.0.0`.

Reasoning:

- The Rust crates are currently separately versioned (`cli` 4.12.0, `server` 3.53.1, `worker` 5.72.0, `gateway` 3.2.0, `tools` 3.21.0). That is fine for crates.io and internal dependency release cadence.
- Python users need one compatible component set. The metapackage version should define that compatibility set and pin exact component wheel versions in extras.
- Component wheel metadata should include the underlying Rust crate version in module constants, e.g. `noetl.worker.__rust_crate_version__ == "5.72.0"`, but the wheel version should match the Python set.
- Start the wrapper line as the next intentional breaking Python line, likely `5.0.0`, because replacing Python implementations with Rust bindings and changing install extras is a public packaging break.

### 7. Risks and mitigations

- Tokio inside PyO3: service loops can deadlock or mishandle signals if `#[tokio::main]` stays buried in bindings. Mitigation: lib-level async entrypoints, one runtime policy, explicit cancellation handles, release GIL.
- Binary size: `noetl-tools` with DuckDB, Arrow, Kubernetes, Wasmtime, TLS, SQLx, and async-nats is heavy. Mitigation: component wheels plus Rust feature flags; keep bare `noetl` pure and small.
- Cross compilation: Linux aarch64 and Windows native stacks may fail around DuckDB/Arrow/TLS. Mitigation: start manylinux x86_64/aarch64 and macOS universal coverage first; gate musllinux.
- Python parity: current package has hundreds of modules. Mitigation: generated replacement map plus built-wheel parity tests before deleting Python code.
- PyPI version skew: local `repos/noetl/pyproject.toml` says 4.24.0, but PyPI shows latest 4.12.1 as of this inspection. Mitigation: decide whether wrappers are 4.x continuation or 5.0.0 reset before upload.
- Name availability: `noetl` is owned; component names were not verified as owned. Mitigation: reserve/create component PyPI projects under the same owner before relying on extras.
- Runtime boundary drift: direct Python DB helpers could violate "server owns NoETL data". Mitigation: Python wrappers call server APIs or Rust server-owned functions; gateway remains gatekeeper only.
- User migration: `noetl.server` and `noetl.worker` imports may change from Python classes/functions to wrappers/handles. Mitigation: deprecation shims for one release where possible, explicit migration notes where not.

### Forks needing human decision

1. Bare install default: I recommend `pip install noetl` = minimal dispatcher/client API, not all components. Confirm this, because `pip install noetl` = all would violate role slicing.
2. Python minimum: choose `>=3.9`/`abi3-py39` if acceptable, otherwise `>=3.10` or keep `>=3.12`.
3. Version line: choose `5.0.0` unified wrapper line versus continuing the current 4.x Python version.
4. Component PyPI project ownership: confirm/create `noetl-cli`, `noetl-worker`, `noetl-server`, `noetl-gateway`.
5. First Phase B slice: choose whether to bind CLI+worker first, then server+gateway, or attempt all four. I recommend CLI+worker first because worker already has a useful lib surface and CLI is the required `run` path.
6. Temporary binary fallback: decide whether it is allowed for gateway/server if lib extraction is larger than expected. I recommend no fallback unless Phase B hits a hard blocker.

## Phase B - Gated

Phase B is blocked until the human says the exact wait phrase: `build python wrappers`.

No Phase B actions were run.

## Issues observed

- Local dirty state existed before this work: `MM repos/cli`, `M repos/noetl`, `M repos/server`, `MM repos/tools`, `M repos/worker`, and the handoff directory was untracked. I did not clean, reset, stash, or edit those repos.
- `repos/noetl/pyproject.toml` local version is `4.24.0`, while PyPI currently reports latest `noetl 4.12.1` released Jun 4, 2026. This needs release-line reconciliation before publishing.
- The current Python wheel has no `[project.scripts]` entry for `noetl`; `noetl/main.py` is retired and `noetl/cli_wrapper.py` shells to a binary. Phase B must replace this with a real dispatcher.
- `repos/gateway` is binary-first with private modules under `main.rs`; it is not ready for PyO3 without lib extraction.
- `repos/cli` is also binary-first and very large (`src/main.rs` contains command parsing, runtime resolution, TUI, auth/context, and command handlers). It needs a careful lib split before binding.

## Manual escalation needed

- Await the wait phrase `build python wrappers` before any implementation.
- Human should decide the forks above, especially bare `pip install noetl` semantics and the unified version.
- Human/PyPI owner must configure trusted publishing and component project ownership before any upload. No upload should be attempted from this round.

## Sources checked

- Maturin configuration and distribution docs: https://www.maturin.rs/config.html and https://www.maturin.rs/distribution.html
- PyO3 building/distribution and abi3 docs: https://pyo3.rs/main/building-and-distribution
- PyPI `noetl` project page: https://pypi.org/project/noetl/
- PyPI trusted publishing docs: https://docs.pypi.org/trusted-publishers/ and https://docs.pypi.org/trusted-publishers/adding-a-publisher/
- Maturin issue on binary plus library wheels: https://github.com/PyO3/maturin/issues/368
- Polars Python package reference: https://github.com/pola-rs/polars/tree/main/py-polars and https://raw.githubusercontent.com/pola-rs/polars/main/py-polars/pyproject.toml
