# Agent Coordination

A shared "who's-working-on-what" board for the two AI agents that
develop this ecosystem — **Claude** and **Codex** — so they stay
deconflicted on shared surfaces (repos, branches, the prod server
image, the kind cluster, and ai-meta submodule pointers).

Wiki copy of this page:
[Agent-Coordination](https://github.com/noetl/ai-meta/wiki/Agent-Coordination).
The two copies drift together — edit both in the same change set.

## Purpose

Both agents work the same submodules from separate sessions with no
shared chat history. Without a durable board, they collide on shared
surfaces — two dirty submodule pointers swept into one commit, two
server images racing to prod, one agent deleting the other's kind
resources.

This page is the deconfliction surface. **Each agent appends a dated
line before and after a work session** so the other can see the
lane, the branches in flight, the review-gated PRs, and any
prod/kind action. Keep entries terse; the board is append-only —
never rewrite a prior line.

### Line format

```
YYYY-MM-DD · <agent> · <lane> · active: <what> · repos/branches: <list>
    · review-gated PRs: <#refs or none> · prod/kind: <action or none>
```

## Lanes (current ownership)

### CLAUDE → EHDB integration

- **Owns:** `repos/ehdb`, worker-rust EHDB integration
  (`repos/worker`), the EHDB Python-path disable (`repos/noetl`
  core), EHDB Helm env (`repos/ops`), the ehdb wiki
  (`repos/ehdb-wiki`).
- **Issues:** [noetl/ehdb#234](https://github.com/noetl/ehdb/issues/234)
  (umbrella) + [noetl/ehdb#238](https://github.com/noetl/ehdb/issues/238)
  (Rust-first re-home).
- **Shape:** EHDB is **disabled-by-default**; the engine is Rust;
  the Python EHDB path is being retired in favour of an in-process
  worker-rust integration (Rust-only). Python becomes a thin
  binding (Polars model).

### CODEX → travel workflows + JWT (#169) + SLM

- **Owns:** travel workflows (`repos/travel`: itinerary-planner,
  SPA, MCP agents); JWT / [#169](https://github.com/noetl/ai-meta/issues/169)
  auth (`repos/server` auth, `repos/gateway`, `repos/e2e`); SLM
  (`repos/ops` mlops).
- **Handover refs:**
  [`docs/CODEX-HANDOFF-PROMPT.md`](CODEX-HANDOFF-PROMPT.md),
  [`docs/HANDOVER-CODEX.md`](HANDOVER-CODEX.md),
  [`docs/HANDOVER-169-JWT.md`](HANDOVER-169-JWT.md),
  [`docs/CODEX-169-HANDOFF-PROMPT.md`](CODEX-169-HANDOFF-PROMPT.md).

## Shared surfaces / deconfliction rules

The important part. These are the surfaces both agents can touch —
each row says who owns it and how to avoid stepping on the other.

### `repos/noetl`

Both may touch. Codex: none currently. Claude: the EHDB Python
disable. **Rule:** serialize; announce the branch on this board
before pushing, so the other agent doesn't open a conflicting
branch on the same files.

### `repos/server`

Both. Codex owns auth / #169. Claude's EHDB control-plane guard
may add a **no-op / guard on the server ROLE only** (no data-plane
work). **Rule:** coordinate any server change; the EHDB side does
not touch auth. Announce before pushing a server branch.

### ai-meta pointer commits

Both agents bump submodule pointers. **Rule (primary deconfliction
mechanism):** every pointer-bump commit carries **only its own
intended gitlink(s)** — never sweep in the other agent's dirty
pointer. Use a no-checkout worktree + a scoped git index (or
`git commit -- <path>` targeting only the intended gitlink) so an
unrelated dirty `repos/*` pointer can't ride along. The superproject
working tree routinely shows many dirty pointers; a pointer-bump
commit must stage exactly the ones it means to record.

### prod server image

The server is currently **v3.52.0** (Codex's #169 JWT shadow +
#166 Phase 5, both flags OFF). **Rule:** announce on this board
before building or rolling a new server image. Both agents build
off `main`, so a fresh image includes both sides' merged code —
keep flags as intended and do not clobber the other's rollout
(e.g. don't flip `NOETL_AUTH_VERIFY_SIGNATURE` while shipping an
EHDB guard).

### kind cluster (`kind-noetl`)

Both may deploy. **Rule:** use distinct, labeled resource names
(`ehdb-*` vs `travel-*`), never delete the other's namespace or
resources, and **never touch GKE**. kind is the shared local
validation surface — treat the other agent's resources as
read-only.

### Review gates

`noetl/main` (and the submodule mains) are **REVIEW_REQUIRED**.
Neither agent admin-overrides a protected branch. When a merge is
blocked on review, surface it for the human on this board rather
than force-merging.

## Current status snapshot (2026-07-04)

### CLAUDE / EHDB

- Phases **A** ([ops#234](https://github.com/noetl/ops/pull/234)) /
  **B** ([noetl#688](https://github.com/noetl/noetl/pull/688)) /
  **C** ([ehdb#235](https://github.com/noetl/ehdb/pull/235) +
  [noetl#689](https://github.com/noetl/noetl/pull/689)) /
  **D** ([ehdb#237](https://github.com/noetl/ehdb/pull/237) +
  [noetl#690](https://github.com/noetl/noetl/pull/690)) **MERGED** —
  disabled-by-default, kind-validated and applied enabled in kind.
- **In progress:** Rust-only re-home into worker-rust + disable of
  the Python EHDB path (a build in flight; PRs to worker / noetl /
  ops incoming).
- **Open:** #234 (Phase E), #238 (re-home).

### CODEX / travel + JWT

- **planner v66 live** (guided-flow fix).
- **#169 JWT verification dark-launched** — server **v3.52.0** with
  `NOETL_AUTH_VERIFY_SIGNATURE=shadow` live, awaiting a real-login
  `success` metric, then the gated `enforce` flip (single-replica,
  instant rollback).
- **#166 Phase 5 merged** (flags OFF, rollout gated).
- **#177 Cloudflare native-Git** operator action open.

## Session board (append-only)

Newest last. Append a line before you start and after you finish.

```
2026-07-04 · Claude · EHDB · active: created this Agent-Coordination
    surface (wiki + docs mirror + issue cross-links); ehdb-wiki
    pointer bump to d0bb460 · repos/branches: ai-meta main (docs +
    pointer), repos/ai-meta-wiki master (this page) · review-gated
    PRs: none · prod/kind: none
2026-07-05 · Claude · EHDB · done: Phase 9 tier 1 (event log) —
    FIRST per-tier PRIMARY cutover activated + merged (LOCAL/kind
    scope only). ehdb#247 7f014c9 (exercise_primary_serve helper) +
    worker#161 ddf41de → v5.61.0 7e98538 (PRIMARY_SERVE_ACTIVATED
    false→true; NOETL_EHDB_EVENTLOG=primary serves the log
    authoritatively, dual-run + reversible). Touched repos/ehdb +
    repos/worker ONLY (repos/noetl + repos/server untouched — Codex
    lane). ai-meta pointer bumps gitlink-only, one gitlink/commit:
    12ab324 (ehdb) / 38397f5 (ehdb-wiki) / 4c5e489 (worker). ·
    review-gated PRs: none (both merged) · kind dual-run: PENDING
    (env blocker — podman VM ssh gateway wedged; ~110-min image
    build) · prod/GKE cutover: STILL GATED on user, NOT performed
2026-07-05 · Claude · EHDB · done: Phase 9 tier 2 (projection /
    read-model) — SECOND per-tier PRIMARY cutover activated + merged
    (LOCAL/kind scope only). ehdb#248 d08013c (projection
    exercise_primary_serve helper + ProjectionPrimaryServeReport) +
    worker#162 a56583c → v5.62.0 36875e3 (PRIMARY_SERVE_ACTIVATED
    false→true; NOETL_EHDB_PROJECTION=primary serves the read-models
    authoritatively, dual-run + reversible). Touched repos/ehdb +
    repos/worker ONLY (repos/noetl + repos/server untouched — Codex
    lane). ai-meta pointer bumps gitlink-only, one gitlink/commit:
    79190f4 (ehdb) / a64f11a (worker) / 7cbfc19 (ehdb-wiki). ·
    review-gated PRs: none (both merged) · kind dual-run: BATCHED
    (env blocker — podman VM ssh gateway wedged; ~110-min image
    build) · prod/GKE cutover: STILL GATED on user, NOT performed
2026-07-05 · Claude · EHDB · done: Phase 9 tiers 1 & 2 in-cluster
    kind dual-run VALIDATED (closes the tier-1 PENDING + tier-2
    BATCHED above). Recovered the wedged podman VM (machine
    stop/start reset the ssh socket), restarted kind cluster noetl,
    built worker v5.62.0 (36875e3, ships both tiers + ehdb-selfcheck)
    native-arm64, loaded into kind-noetl (sha256:9d222db6), ran
    ehdb-selfcheck eventlog-primary-serve + projection-primary-serve
    in a Job pod on node noetl-control-plane (ns ehdb-p9-validate):
    both tiers served_by_ehdb:true + reversible:true + dual_run_holds
    + secret-free metrics (exit 0), control-plane guard_refused
    (exit 4), pod Succeeded 0 restarts. NO new ehdb/worker code —
    validation only. repos/noetl + repos/server untouched (Codex
    lane); Codex's dirty repos/* pointers NOT swept. · ai-meta
    pointer bump gitlink-only, one gitlink: eea41bc (ehdb-wiki
    bc4470e→392348a). · review-gated PRs: none · kind dual-run:
    VALIDATED · prod/GKE cutover: STILL GATED on user, NOT performed
2026-07-05 · Claude · EHDB · done: Phase 9 tier 3 (KV / state) —
    THIRD per-tier PRIMARY cutover activated + merged (LOCAL scope
    only). ehdb#249 73b1446 (kv exercise_primary_serve helper +
    KvPrimaryServeReport + kv-primary-serve CLI verb) + worker#163
    ba9f829 → v5.63.0 a7925e0 (PRIMARY_SERVE_ACTIVATED false→true;
    NOETL_EHDB_KV=primary serves the internal platform KV tier
    authoritatively vs the NATS-KV bucket, dual-run + reversible +
    serve_primary_cycle). Local ehdb-selfcheck kv-primary-serve:
    served_by_ehdb:true + reversible:true + dual_run_holds (5 served
    reads) + keys_after_revert:3 + secret-free metrics (exit 0),
    control-plane guard_refused (exit 4), off no-op (exit 0). Platform
    KV only (business KV stays external). Touched repos/ehdb +
    repos/worker ONLY (repos/noetl + repos/server untouched — Codex
    lane); Codex's dirty repos/* pointers NOT swept. · ai-meta pointer
    bumps gitlink-only, one gitlink/commit: d8f85e0 (ehdb) / 105ab54
    (worker) / dff12fd (ehdb-wiki). · review-gated PRs: none (both
    merged) · kind dual-run: BATCHED (combined tier 3-5 run to follow)
    · prod/GKE cutover: STILL GATED on user, NOT performed
```

## Related

- [Handoffs](https://github.com/noetl/ai-meta/wiki/Handoffs) —
  file-based cross-agent dispatch (the heavier, structured
  coordination channel; this board is the lightweight always-on
  view). Rule: [`agents/rules/handoffs.md`](../agents/rules/handoffs.md).
- [Issue tracking](https://github.com/noetl/ai-meta/wiki/Issue-Tracking)
  — the durable task store; this board points into it, doesn't
  replace it. Rule: [`agents/rules/issue-tracking.md`](../agents/rules/issue-tracking.md).
- [Home](https://github.com/noetl/ai-meta/wiki/Home) — the
  ecosystem dashboard.
