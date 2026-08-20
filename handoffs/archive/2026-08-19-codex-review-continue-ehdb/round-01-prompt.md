---
thread: 2026-08-19-codex-review-continue-ehdb
round: 1
from: claude
to: codex
created: 2026-08-20T03:20:00Z
status: revoked
expects_result_at: round-01-result.md
---

# Codex Task — independently REVIEW the EHDB program, then continue it

> **REVOKED — 2026-08-19.** Revoked by the user: Codex was crashing and
> never produced a result for this round. The EHDB review-and-continue
> work is **not** being pursued through this handoff. No result file was
> written by the executor; `round-01-result.md` is a dispatcher-written
> stub recording the revocation. Thread archived unstarted — nothing in
> this prompt was acted on.



## Objective

Two deliverables, strictly in order.

1. **A review report.** Independently verify what the EHDB program has
   actually achieved — especially the event-log tier now serving `primary` on
   prod and the just-shipped async-mirror latency work — and write it up.
   **This is the first deliverable and it lands before you change any code.**
2. **Continue the program.** Only after the review, pick up the
   highest-value *unblocked* pending EHDB task that your own review
   identifies, and carry it forward.

The review is not a formality and not a summary of what you were told. **Every
claim in this prompt is a claim, not a fact.** Several statements in this
repo's issues, wiki pages and memory files have turned out to be stale or
wrong — including, in the last session, the agent's own memory index asserting
"zero alerting on prod" for two weeks after that was fixed, and an issue body
whose premise had been false since it was written. Treat what follows as
pointers to check, not conclusions to inherit.

If you find that something below is wrong, **say so in the report** — that is
the single most valuable outcome this round can produce.

## Background — where things stand (verify all of it)

### Repo layout

Work under `repos/<name>` in this superproject. The EHDB engine crates live in
`repos/ehdb` (at `a7dd0ef` as of writing); the NoETL side that consumes them is
`repos/server` (the control plane) and `repos/worker` (the data plane, which
also hosts the tier service). Manifests and monitoring are in `repos/ops`.
Wiki: `repos/ehdb-wiki` (see `Roadmap.md`, `Architecture.md`,
`Design-Projection-Read-Model-Engine.md`,
`Design-KV-Object-Vector-Engines-Phase-8.md`,
`Runbook-Prod-Cutover-EventLog.md`, `Program-EHDB-NATS-Takeover.md`).

### Claimed tier state (CHECK IT)

Read off the prod worker deployment at the time of writing:

```
NOETL_EHDB_ENABLED=true
NOETL_EHDB_MODE=local_reference
NOETL_EHDB_EVENTLOG=primary        <-- tier 1, claimed SERVING
NOETL_EHDB_PROJECTION=shadow       <-- tier 2, proven in kind, NOT serving
NOETL_EHDB_KV=shadow
NOETL_EHDB_OBJECT=shadow
NOETL_EHDB_TIER_QUERY_SOURCE=service
NOETL_EHDB_TIER_SERVICE_ADDR=noetl-cmdbus-writer-0.noetl.svc.cluster.local:9110
NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server
```

⚠ **`NOETL_EHDB_VECTOR` is not set at all** — not shadow, not off, absent. Work
out what that means for the vector tier and whether the "five tiers" framing in
the wiki is accurate.

Prod server:

```
NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server
NOETL_EHDB_WORKER_QUERY_URL=http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090
NOETL_EHDB_CROSSSTORE_PARITY_ENABLED=true
NOETL_EHDB_EVENTLOG_MIRROR_ASYNC=true
NOETL_EHDB_CROSSSTORE_PARITY_LAG_TOLERANCE_SECS=30
```

Deployed versions: **server `v3.83.1`**, user-pool worker **`v5.120.0`**,
`cmdbus-writer` StatefulSet **`v5.119.1`** (deliberately held back — it carries
the durable log and rolls as its own watched step), system pools **`v5.118.2`**.
Confirm these from each process's own `build_info` metric rather than from the
Deployment's image tag; the two can disagree.

### The latency arc just completed (ai-meta#155)

Read [noetl/ai-meta#155](https://github.com/noetl/ai-meta/issues/155) and its
comments end to end — it is the design record. In short, three options were
pursued against a Muno planner turn:

- **Option 1 — runtime replay cache.** `NOETL_EHDB_REFERENCE_RUNTIME_CACHE`
  (ehdb#316). The tier driver was reopening and replaying the entire ~161 MB
  JSONL log on *every* operation. Cache one runtime per log path. Live on the
  **writer** (v5.119.1), which is where the tier store lives.
- **Option 2 — batch append substrate.** `NOETL_EHDB_TIER_APPEND_BATCH`
  (ehdb#317 + worker#281): one open, N writes, one `fsync`. Measured **inert**
  under a synchronous mirror and deliberately shipped without a coalescing
  window; it only becomes useful once a queue exists.
- **Option 3 — async mirror.** `NOETL_EHDB_EVENTLOG_MIRROR_ASYNC` (server#353).
  Moves the mirror off the `emit_events` hot path behind a bounded queue with a
  three-rung backpressure ladder and, by design, **no drop rung**. Shipped
  together with a **comparator lag-tolerance window**, because the cross-store
  comparator had no recency bound and would otherwise report `missing_event`
  for events merely sitting in the queue.

Claimed prod outcome: `emit_mirror` 78.6–87.6 ms/call → **0.1 ms/call**
(~6.0 s → 0.007 s per turn), median warm turn 16.9 s → 13.0 s. Measured lag
p99 699 ms, max < 1 s, window then set to 30 s.

A follow-up fix (server#354 → v3.83.1) stopped a `pending_mirror` verdict from
writing `crossstore_divergence_total`, the counter the paging alert reads.

## Phase A — ORIENT (read-only)

1. Read `AGENTS.md` and everything it points at, especially
   `agents/rules/execution-model.md`, `data-access-boundary.md`,
   `representation-drift.md`, `deployment-validation.md`,
   `commit-conventions.md` and `issue-tracking.md`.
2. Read `memory/current.md` and the recent entries under `memory/inbox/`.
3. Read the EHDB wiki pages listed above, and the four-page ai-meta wiki
   dashboard (`Home.md`, `Sessions-Log.md`, `Releases.md`, the relevant
   `Umbrella-*.md`).
4. Read the git history and the working tree of `repos/ehdb`, `repos/server`,
   `repos/worker`, `repos/ops`. **Do not clean or reset anything** — see
   Guardrails.
5. Read ai-meta#155 and its comment thread.
6. Skim the open EHDB-adjacent issues so your pending-task list is grounded:
   ai-meta **#265** (projection tier), **#257** (primary serve RFC), **#247**
   (tier serve-flips / shadow evidence), **#262** (torn record: fail the scan or
   skip and report), **#260** (tier service records no metrics), **#258**
   (cross-store parity), **#199** (write-behind sink), **#248** (sink gate /
   boundary compaction), **#227** (in-flight executions do not resume after a
   writer restart), **#232** (no `cargo test` in CI on any Rust repo); and
   ehdb **#241**, **#254**, **#261**, **#234**.

## Phase B — REVIEW (mandatory first deliverable; no code changes)

Produce a review report. Verify against **code and running state**, not against
prose. Where you cannot verify something, say "unverified" rather than
restating the claim.

### B1 — Tier architecture and serve state

- What the five tiers are, which are wired to a runtime serve decision, and
  which have a `serve_primary_cycle` whose only caller is a conformance binary.
  A tier can be flag-selectable and still be unable to change any caller's
  answer; distinguish those cases explicitly.
- Confirm or refute: event-log is `primary` **and actually serving** on prod.
  `served_primary` is **per-pod** — the mirror relay targets a Service, so one
  replica can hold every count and another read 0. Sum across replicas.
- Confirm or refute: projection (tier 2) is proven in kind and not serving.
  ⚠ ai-meta#265 records that the tier's charter named `noetl.projection`, a
  **dead table with 0 rows and no Rust writer**; the real store is
  `noetl.projection_snapshot` with exactly one INSERT site. Check which the
  current code actually targets. Also check the coverage problem recorded
  there: a 13-event execution can complete and produce **no snapshot row at
  all**, which makes "0 divergences" vacuous without a coverage denominator.
- KV / object / vector: what exists, what is reachable, what is inert. Note the
  missing `NOETL_EHDB_VECTOR` above.

### B2 — The async mirror work (ai-meta#155)

Verify the correctness of what shipped, not just its presence.

- **The comparator lag tolerance.** `compare_cross_store_with_horizon` in
  `repos/server/src/handlers/ehdb_parity.rs`. The property to test is a
  *discrimination*: it must tolerate an event that is merely queued **and still
  report one that is genuinely missing past the window**. A tolerance that
  forgives everything passes a naive "clean parity" test perfectly. Check the
  two in-binary controls (`lag_within_window` / `lag_beyond_window`), whether
  they run on the live path, and whether the horizon is computed so a
  still-queued event can never land inside the compared set.
- **Queue conservation and backpressure.** `ehdb_eventlog_mirror_queue.rs`.
  Confirm `enqueued == drained`, that no path discards a batch, and that the
  inline-fallback rung cannot silently reorder without being metered. Note the
  bug found in review last session: the first implementation used
  `tx.send(batch)`, whose value is moved into the future, so a timeout
  cancellation **discarded the events while every counter still read
  correctly**. Check nothing equivalent remains.
- **Shutdown flush.** Whether SIGTERM drains the queue, and what happens to
  anything still pending.
- **Serve-policy safety.** Confirm `primary_serve::decide`'s
  demote-on-divergence guarantee is intact and that the #155 work did not
  weaken it. Establish for yourself whether a cross-store divergence has any
  automatic path to that decision, or whether it is an operator/alert signal —
  the two are often conflated in the issue text.
- **The read-skew fix** (server#354): tier records above the authoritative
  page's max id are excluded when a horizon is active. Check the bound is taken
  from the **full** page and not the comparable prefix, and that a real
  `extra_event` below the max still reports.

### B3 — Tests, gaps, and risks

- Test coverage across `repos/ehdb`, `repos/server`, `repos/worker` for the
  above. ⚠ ai-meta#232: **no `cargo test` runs in CI on any Rust repo**, so a
  red test reaches `main` and stays. Actually run the suites.
- Look for guards that cannot fire, tests carrying no `#[test]`, metrics with
  no caller, and counters that count their own source text — all four have
  occurred in this codebase.
- Any claim in this prompt, in ai-meta#155, or in the wiki that does not hold.

### B4 — Report

State plainly:

- **Genuinely done and verified** — with the evidence you used.
- **Claimed but unproven** — and what would prove it.
- **Bugs / correctness risks found**, with severity.
- **Prioritized pending EHDB tasks**, each marked blocked or unblocked with the
  blocker named, and **the single highest-value unblocked one identified**.

Write this as `round-01-result.md` per the FINAL REPORT section and **stop for
review before Phase C.**

## Phase C — CONTINUE

Pick up the highest-value **unblocked** task your review identified and carry it
forward. The likely candidates are projection-tier serve-readiness (ai-meta#265)
and then KV/object/vector serve wiring — but **your review decides**, not this
prompt. If the review shows the highest-value work is something else entirely
(a correctness bug, the missing CI test runner, the torn-record decision), say
so and do that instead.

Follow the same discipline the event-log tier's promotion used: shadow first,
evidence before flags, kind validation before prod, and a coverage denominator
so a zero divergence count means something.

## Guardrails — state these back in your report

- **Do NOT flip any EHDB serve tier or change prod serve config without
  explicit human go-ahead.** No `NOETL_EHDB_*` tier mode changes on prod.
- **The async mirror is LIVE and healthy — do not disturb it.**
  `NOETL_EHDB_EVENTLOG_MIRROR_ASYNC=true`,
  `NOETL_EHDB_CROSSSTORE_PARITY_LAG_TOLERANCE_SECS=30`. If you believe either
  should change, propose it in the report; do not act.
- **Do NOT push commits** unless explicitly asked. Commit locally, per
  `agents/rules/commit-conventions.md`.
- **Preserve unrelated work.** At the time of writing, **15 `repos/*`
  submodules are dirty** from prior sessions (`cli`, `docs`, `e2e`, `ehdb`,
  `ehdb-wiki`, `gateway`, `noetl`, `noetl-ops-wiki`, `noetl-tools-wiki`,
  `noetl-wiki`, `ops`, `server`, `tools`, `travel`, `worker`). **Do not
  `git checkout .`, `git reset --hard`, `git clean`, or stage anything you did
  not author.** If you need an isolated tree, clone the submodule's upstream
  into a scratch directory — and note that `git worktree` against a submodule
  is a known trap here (ai-meta#239).
- **Validate before every commit**: Python compiles, JSON/YAML parses,
  `git diff --check`, plus `cargo build --all-targets` and `cargo test` for any
  Rust touched. `cargo build --lib` alone does not compile `cfg(test)` code.
- **Credentials by reference only.** Never print or commit a secret value.
  This repo is public.
- **Prod reads are fine; prod writes are not, absent a go-ahead.** The default
  `kubectl` context is **PROD** — pass `--context kind-noetl` explicitly for
  every kind command.
- Follow `agents/rules/wiki-maintenance.md` and `issue-tracking.md` if your work
  reaches a public surface.

## FINAL REPORT

Write the body of `round-01-result.md` with this frontmatter:

```yaml
---
thread: 2026-08-19-codex-review-continue-ehdb
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then one H2 per phase (A, B, C), plus:

- `## Issues observed` — include **grep-able fingerprints**: real error strings,
  exit codes, failing test names, SHAs. Do not paraphrase them.
- `## Manual escalation needed` — anything requiring a human decision or a
  credential you do not have.

If Phase B finds something that changes what Phase C should be, say so and stop
rather than improvising around it.
