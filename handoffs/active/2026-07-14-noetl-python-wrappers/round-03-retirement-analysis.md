---
thread: 2026-07-14-noetl-python-wrappers
round: 3
from: claude
to: human
created: 2026-07-24
status: analysis-for-review
tracks: noetl/ai-meta#201
---

# Stage 4 — Python retirement: evidence list + deprecation plan

**No deletions in this round.** This is the evidence-backed inventory
the human asked for. Each Python module is mapped to the Rust surface
that supersedes it (if any), with every place it is *still referenced*
called out, so the deletion decision is made on facts rather than the
round-02 assumption list.

Surveyed at `repos/noetl` origin/main `ff3a920f`. The round-02 prompt's
proposed list was `server / worker / tools / outbox / projector /
database / main.py / install.py`. **That list is wrong on `database`**
(see below) and treats several trees as clean when they are still
load-bearing for tests, docs, and the dev/kind deploy path.

## Precedent — how this team retires a Python path

Three commits before the survey point, `noetl#691`
(`chore(ehdb): retire the Python EHDB integration path (Rust-only)`,
`312ad3f4`) removed 7 `noetl/core/ehdb_*.py` modules + scripts in one
clean commit once the Rust EHDB path was authoritative. That is the
shape to copy: **one `chore(retire):` commit per tree, after its Rust
replacement is confirmed authoritative in every consuming path — not a
big-bang deletion.**

## Verdict table

| Python module | LOC | Superseded by (Rust) | Still referenced by | Verdict |
|---|---|---|---|---|
| `noetl/cli_wrapper.py` | 61 | **This wheel** (PyO3 over `noetl::cli_main`) | nothing (no console_script wired to it in `pyproject.toml`) | **RETIRE** with the wheel cutover |
| `noetl/main.py` | 26 | n/a — already a retired stub that exits 1 | nothing | **RETIRE** (dead stub) |
| `noetl/install.py` | 80 | **This wheel** (binary is compiled into the extension; nothing to install) | nothing | **RETIRE** with the wheel cutover |
| `noetl/server/` | 25,251 | `repos/server` (Rust `noetl-server`) | 56 test files; ops manifests (`server-deployment.yaml`, `configmap-server.yaml`); `docker/noetl` image; README + wiki | **DEPRECATE → retire** after test/doc/ops migration |
| `noetl/worker/` | 11,056 | `repos/worker` (Rust `noetl-worker`) | 20 test files; `configmap-worker.yaml`; `docker/noetl` startup | **DEPRECATE → retire** after test/doc/ops migration |
| `noetl/tools/` | 17,405 | `repos/tools` (Rust `noetl-tools`, which this wheel binds) | 25 test files; `noetl/worker` imports it (1 site) | **DEPRECATE → retire** with the Python worker |
| `noetl/outbox/` | 117 | Rust server per-shard publish (#166 Phase 5, in prod) | 3 test files; README documents `python -m noetl.outbox` as current | **DEPRECATE** — fix docs first |
| `noetl/projector/` | 55 | Rust off-server state builder (#115 / #166) | `configmap-projector.yaml`; README documents `python -m noetl.projector` as current | **DEPRECATE** — fix docs + ops first |
| `noetl/claim_policy.py` | 61 | folded into Rust server command handling | imported by `noetl/server/command_reaper.py` + `api/core/commands.py`; 1 test | **RETIRE with `noetl/server`** — not independently |
| `noetl/core/` | 40,327 | partially: `repos/executor` + `repos/server` + `repos/tools` | 90 test files; imported by server (61) + worker (18) | **KEEP for now** — see below |
| `noetl/database/` | 380 | **nothing** | **the Rust server itself** + ops deploy | **KEEP — load-bearing** |

## The two findings that break the round-02 assumption

### 1. `noetl/database/` is NOT retirable — the Rust stack depends on it

`noetl/database/ddl/postgres/schema_ddl.sql` (1,051 lines) is the
source-of-truth platform schema. It is:

- **Consumed by the ops deploy** for the Rust stack:
  `repos/ops/automation/development/noetl.yaml:262` reads
  `$NOETL_REPO/noetl/database/ddl/postgres/schema_ddl.sql` and loads it
  into the `postgres-schema-ddl` configmap during bring-up.
- **Referenced by the Rust server as canonical**, in its own comments:
  - `repos/server/src/main.rs:963` — "canonical definition also lives
    in noetl/noetl's schema_ddl.sql"
  - `repos/server/src/db/queries/catalog.rs:13`,
    `event_chain.rs:11,27,74` — "the canonical definition is
    schema_ddl.sql in noetl/noetl".

The Rust server does **not** own its schema; it expects this DDL to be
provisioned. Deleting `noetl/database/` breaks the Rust deploy. This
tree stays until schema ownership is deliberately moved into
`repos/server` — a separate, larger decision, not part of the CLI-wheel
work.

### 2. `noetl/core/` is 40k LOC and 90 test files — not a Stage-4 delete

`core/` is the Python DSL engine, event/projection stores, auth,
secrets, cache, and the DSL schema generator
(`python -m noetl.core.dsl._generate_schema`, referenced from
`.github/playbook-structure-reference.md:365`). Much of it is mirrored
by `repos/executor` + `repos/server`, but it is imported by the Python
server (61 files) and worker (18 files), so it cannot go before they
do, and even then the DSL-schema generator may need a home. **Out of
scope for the CLI-wheel retirement; own umbrella if pursued.**

## Proposed deprecation plan (for review — nothing executed)

Sequenced so nothing breaks a consumer that still exists:

**Phase R0 — with the wheel cutover (safe now, tiny):**
Retire `cli_wrapper.py`, `main.py`, `install.py`. All three are
superseded by this wheel and have zero live references. One
`chore(retire):` commit, matching the `noetl#691` precedent. Ship after
the wheel is the primary distribution.

**Phase R1 — documentation truth-up (no code, unblocks R2/R3):**
The README + wiki still present `python -m noetl.outbox` and
`python -m noetl.projector` as the current runtime. Rewrite those to
point at the Rust server's publish/projection path (the prod reality
since #166 Phase 5). Until this lands, retiring outbox/projector would
delete code the docs still tell operators to run.

**Phase R2 — ops migration (ops repo, gated on R1):**
Remove / archive the Python deployment manifests still in
`repos/ops/ci/manifests/noetl/` (`server-deployment.yaml`,
`configmap-{server,worker,projector}.yaml`, the `docker/noetl`
Python image build) once every environment is confirmed on the
`-rust` deployments. This is ops-repo work; flag for the ops owner.

**Phase R3 — Python server/worker/tools/outbox/projector/claim_policy
retire (gated on R1 + R2 + test migration):**
Once no deploy path and no doc references the Python runtime, retire
`server/`, `worker/`, `tools/`, `outbox/`, `projector/`, and
`claim_policy.py` together (they form one import cluster — `claim_policy`
and `tools` are pulled in by `server`/`worker`). The **156 test files**
referencing these must first be either deleted (if they test retired
behavior) or re-pointed at the Rust stack's e2e suite (`repos/e2e`).
That test-migration is the real cost and needs its own issue.

**Deliberately NOT scheduled:**
- `noetl/database/` — load-bearing for the Rust deploy (finding #1).
- `noetl/core/` — 40k LOC, own umbrella if pursued (finding #2).

## Recommendation

Do **Phase R0 only** as a fast follow to the wheel (three dead files,
zero risk), and open a separate tracking issue for R1→R3 with the
test-migration cost called out. R0 is the only piece that is genuinely
"superseded by this wheel with no live references" — the rest is a
platform-migration project, not a packaging cleanup, and the round-02
"delete the service modules" framing understated it.
