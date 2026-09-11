---
loop: 2026-09-11-ehdb-resilient-core-phases
status: active
created: 2026-09-11T23:30:00Z
owner: Claude (ai-meta session 2026-09-11)
---

# Drive the EHDB resilient-core phases, build → verify → iterate

Spec: [`specs/active/2026-09-11-ehdb-resilient-core/spec.md`](../../../specs/active/2026-09-11-ehdb-resilient-core/spec.md)
Overview (repo-owned): [EHDB wiki — Architecture: resilient KV core](https://github.com/noetl/ehdb/wiki/Architecture-Resilient-KV-Core)
Coordination: noetl/ai-meta#339

## Goal

Move EHDB from "replication API exists" to "replication is real", one reversible
phase at a time, each landing as a merged PR with tests **and** a mutation gate.

Checkable definition of done **per phase** — a phase is done only when:

- the capability has a **production caller** (not just an implementation), proven
  by call-site count with a control needle;
- a mutation that removes or inverts it is **caught**;
- the change is revertible by a single named step.

⚠ "Implemented" is not done. Phases 1 and 2 were already shipped and unnoticed;
Phase 3 exists entirely as uncalled API. **Reachability is the bar.**

## Stop Conditions

- **Success:** Phase 3 and Phase 4 land merged with production callers and
  mutation gates, and the Phase-5 library decision (Q1) is made against a
  harness rather than documentation.
- **Hard bounds:**
  - max iterations = **8** (one iteration = one phase slice built and verified)
  - max wall-clock = **6 hours** of active work
  - max cost/token budget = **one session's context**; if context is heavily
    loaded while the loop is open, **stop and hand off** — this programme has
    produced miscounts under exactly that condition.

⚠ **Hard stop, independent of the bounds:** any phase step that would change prod
ends the loop and goes to the owner. Prod changes in this programme are
owner-gated without exception. The loop is build-and-verify only.

## Checkpoint Cadence

One entry under `## Iterations` per slice: which phase, what was built, the
mutation result (caught/survived), and **any measurement that turned out to be
invalid, with why**. Record false zeros — they are the recurring failure here.

## State Source

Resumes from this file plus:
- the phase table in the wiki overview (states are corrected against prod there);
- `noetl/ehdb` and `noetl/server` PR state;
- prod metrics for the phases already shipped (read-only).

## Escalation Path

- **A phase needs a prod change** → stop, hand the gated step to the owner with a
  full-spec diff and a rehearsed revert. Do not apply.
- **Q1 (Raft library) cannot be decided from a harness within bounds** → open a
  tracked issue with the harness results so far and stop; do not pick a
  consensus library on vibes.
- **A phase turns out to be already shipped** (as 1 and 2 were) → record it,
  correct the spec and the wiki, and move on rather than building it again.

## Iterations

- Iteration 0 (2026-09-11) — loop opened. Phase states **corrected against prod**
  rather than assumed: Phase 1 (measure the window) and Phase 2 (bound it) are
  **already live** — both engines export `ehdb_l0_unreplicated_*` and the writer
  runs `NOETL_EHDB_SEAL_MAX_AGE_MS=5000`. Phase 3 is next and is entirely
  unwired: `open_replicated` and `validate_replica_domains` have **no production
  callers**, and `TIER_SERVICE_DIR` is nested inside `EVENT_BUS_WRITER_DIR` on
  one PVC.

## Outcome

(filled in by `loop-close`)
