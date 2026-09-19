---
spec: 2026-09-19-slm-ehdb-context-S0
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# S0 — Prove the event envelope takes new optional body fields additively

Phase of [`spec.md`](spec.md). **Planning only.**

## Scope

Prove, before any SLM work exists, that adding `Option<T>` fields to the event
record **body** is additive: an old reader parses a new log, and a new reader
parses an old log. Prove the frame header is untouched.

**In scope:** the envelope, its serde, the 12-byte header, and the mutation
battery.
**Out of scope:** anything SLM. S0 emits no new event type. It ships a proof and
possibly a test, nothing else.

## Flags

**None.** A flag with one legal value is a representation that drifts. S0
introduces no behaviour to gate.

## Why this is first

If the envelope cannot take additive fields, S1's six event types are a format
break and S1–S5 are all invalid. Discovering that at S3 wastes three phases.
This is the cheapest possible falsification of the whole plan.

## Touch-points

| File | Current state | Change |
| :-- | :-- | :-- |
| `ehdb-reference/src/fencing.rs` | **VERIFIED via handover** — `FRAME_HEADER_LEN` is a fixed 12 bytes, byte-identical with `durable_eventlog.rs`; widening it makes existing segments unreadable (C3) | **none.** S0 asserts it is unchanged |
| the event record body type | **ASSUMED** — not read in this session; S0's first act is to locate it and record the path here | add a test-only `Option<T>` field |
| `repos/server/src/handlers/event_write.rs` (`EventRow`) | **VERIFIED** it exists — `execute.rs` calls `crate::handlers::event_write::EventRow::new` | round-trip under test |

⚠ The middle row is the honest state: I did not read the body type this session.
S0 must not begin by assuming its shape.

## Acceptance criteria

- **A1** — a body with an unknown `Option<T>` field round-trips through the
  current serde without error and **without dropping the unknown field** on
  re-serialise, or, if it does drop it, that is recorded here as a finding and
  S1's design changes to suit.
- **A2** — `FRAME_HEADER_LEN` is asserted equal to 12 by a test that fails if it
  changes.
- **A3** — a log written with the extra field is readable by a build without it.
- **A4** — a log written without it is readable by a build with it.

## Instrument

A round-trip test plus a byte-level assertion on the header length. Not the
parity comparator, not the fold-diff endpoint (⛔ forbidden, umbrella §Constraints).

## RED→GREEN control

Plant the defect in the **header**, not the body: widen `FRAME_HEADER_LEN` to 13
in a scratch build and confirm A2 fails and A3 fails. A control that only ever
exercises the body would not prove the header assertion can fire.

**Expected RED:** A2 fails on the constant; A3 fails on a truncated read.
**Then revert and expect GREEN on all four.**

## Rollback

Nothing to roll back — S0 ships a test. If A1 fails, the rollback is to the
**design**: S1 moves to an out-of-band per-shard marker (the C3 escape hatch)
and this spec records why.

## Exit criteria

A1–A4 green, the RED control demonstrated, and the event body type's real path
written into the Touch-points table above, replacing the ASSUMED row.
