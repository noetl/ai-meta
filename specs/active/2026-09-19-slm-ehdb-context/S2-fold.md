---
spec: 2026-09-19-slm-ehdb-context-S2
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# S2 — The deterministic fold into a working context

Phase of [`spec.md`](spec.md). **Planning only.** Depends on **S1**.

## Scope

A pure function from (event prefix for one `execution_id`, fold version) to a
`WorkingContext`, and a shadow comparison against the prompt today's playbook
assembles by hand.

**In scope:** the fold, its version, its determinism proof, the shadow compare.
**Out of scope:** using the fold's output to drive a real call (that is flipping
`NOETL_SLM_CONTEXT_FOLD=on`, gated on this phase's exit).

## Flags

| Flag | Values | Default |
| :-- | :-- | :-- |
| `NOETL_SLM_CONTEXT_FOLD` | `off` \| `shadow` \| `on` | `off` |

## Where it runs

**Server-side, reading D1** (fork F1, recommended). Not in playbook Python: a
second fold implementation cannot be compared against the first, and the
comparison is the whole value of the shadow phase. D3's projection engine is the
later home — deferred to S5, because D3's EHDB engine is shadow, not
authoritative.

## Interfaces

```rust
pub struct FoldVersion(pub u32);          // bumped on ANY semantic change

pub struct WorkingContext {
    pub turns:     Vec<Turn>,             // global_sequence order, per-engine (C5)
    pub admitted:  Vec<StepSpec>,
    pub rejected:  Vec<Rejection>,        // fed back to the model — see below
    pub summaries: Vec<Summary>,          // empty until S5
    pub budget:    Budget,
}

pub fn fold(execution_id: ExecutionId, up_to_seq: u64, v: FoldVersion)
    -> Result<WorkingContext>;
```

⭐ `rejected` is in the context deliberately: a model that is told what it got
wrong stops repeating it, and the alternative — silently dropping rejections — is
how a generate loop burns its whole budget on the same invalid spec.

## Determinism

The fold must be a pure function. Three hazards, each to be closed explicitly:

- **Map iteration order.** Any `HashMap` in the fold output is a determinism
  bug. Use ordered collections or sort before emit.
- **Cross-engine sequence.** Per **C5**, `global_sequence` is per-engine.
  The fold is scoped to one execution on one engine and must assert that rather
  than assume it.
- **Clock reads.** The fold may not read wall-clock time. Anything time-derived
  comes from event payloads.

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `repos/server/src/services/` | **VERIFIED** the replay service exists (`services/replay.rs`) and folds event streams today | the SLM fold joins it as a sibling, reusing its range-scan shape |
| D1 access pattern | **VERIFIED** — §0.1 declares *"append; range-scan after seq; per-execution replay"* | unchanged; the fold needs no new index |

## Acceptance criteria

- **A1** — same prefix, same version → identical `WorkingContext`, across
  processes and across two runs. Byte-compared on a canonical serialisation.
- **A2** — `shadow`: the folded prompt is computed and compared against the
  hand-assembled prompt the playbook sends today; differences are **reported,
  not applied**.
- **A3** — the fold reads only D1 and emits no events.
- **A4** — a fold over an empty prefix returns an empty context, not an error.

## Instrument

A canonical-serialisation digest of `WorkingContext`, compared across two folds.
Plus a shadow-difference counter, **pinned at 0**.
⛔ **Not** `/api/ehdb/projection-fold/diff/{id}` — forbidden while stage-1 is open.
This phase's comparison is in-process and does not use that endpoint.

## RED→GREEN control

Plant non-determinism: replace one ordered collection with a `HashMap` and emit
without sorting. **Expected RED:** A1 fails intermittently — and if it does *not*
fail, the harness is running a single iteration and the determinism check is
decorative. Require ≥ 50 iterations before accepting GREEN.

⚠ A check that passes on one run is not evidence of determinism. That is the
"print the denominator" rule applied to a flaky property.

## Rollback

Flag to `off`. The fold is read-only and emits nothing.

## Exit criteria — ◐ PARTIAL (fold landed; shadow-compare is server wiring)

**Landed:** same commit `9a293da`, module `fold`. `fold()` is pure — no clock,
no I/O, no hash-ordered output. Turns sort by turn number, not arrival.
Unsorted input is **refused** rather than silently sorted; a foreign
`execution_id` is **refused** rather than skipped (C5). Unknown kinds are
counted in `skipped_unknown` so an old build degrades visibly. 13 tests.

**A1 met at 64 iterations** (the spec asked ≥ 50), and the RED control proves
the iteration count is load-bearing: planting a `HashMap` round-trip in place of
the sort fails `same_prefix_same_context_across_many_runs`. Five plants total,
each isolating exactly one test, revert verified after each.

⚠ **The battery's first run was invalid and is recorded rather than hidden:**
`git checkout --` cannot restore an **untracked** file, so the plants
accumulated and the "reverted" run was still red. The baseline is now committed
before planting, and the harness asserts a clean tree after every revert.

**Still open:** A2's shadow comparison against today's hand-assembled prompt is
a server call site, not substrate.
