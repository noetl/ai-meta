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
| `ehdb-stream/src/lib.rs:156` `StreamRecord` | ⚠ **VERIFIED — and it refutes this spec's premise.** It carries `#[serde(deny_unknown_fields)]`. An older reader **rejects** a record with an added envelope field; it does not ignore it | **none.** Do not touch it |
| `StreamRecord.payload: Vec<u8>` | **VERIFIED** — opaque bytes | this is the additive path |
| `ehdb-l0/src/frame.rs:22` | **VERIFIED** — `pub const FRAME_HEADER_LEN: usize = 12` | asserted by test |
| `ehdb-reference/src/durable_eventlog.rs:98` | ⚠ **VERIFIED** — declares its **own private** `FRAME_HEADER_LEN = 12` and `FRAME_MAGIC`, and hand-builds the header at `:841-843`. `ehdb-reference` has **no `ehdb-l0` dependency**, so nothing linked the two | asserted by its own unit test |

## ⚠ Finding — this spec's A1 premise was wrong

A1 asked whether an added `Option<T>` body field round-trips, expecting either
"yes" or "yes but lossy". The real answer is **neither: it is rejected.**
`StreamRecord` is `deny_unknown_fields`, which is correct for an envelope and is
left alone. It moves the additive path to where it already was — the opaque
`payload`. The rule every later phase inherits:

- ⛔ **never add a field to `StreamRecord`** — a format break, loud on read;
- ✅ **add context data inside `payload`**, versioned, `#[serde(default)]` +
  `skip_serializing_if`, proven compatible in both directions.

## ⚠ Finding — the frame format is implemented twice, unlinked

`fencing.rs` calls the format *"shared byte-identically with
`durable_eventlog.rs`"*. True of the **values**, false of the **mechanism**:
they are two independent literals in crates that do not depend on each other. A
change to one was silent in the other, and the failure mode is unreadable
segments, not a compile error. Each crate now pins itself to the same
written-down literal.

## Acceptance criteria

- **A1** — ⚠ **superseded by the finding above.** Restated as implemented: the
  envelope **rejects** unknown fields (asserted), and the **payload** grows
  forward- and backward-compatibly (asserted both directions).
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

## Exit criteria — ✅ MET

A1–A4 green, the RED control demonstrated, and the ASSUMED row replaced by the
verified path.

**Landed:** `noetl/ehdb` branch `feat/slm-context-s0-frame-invariants`,
commit `bdf9b5a`. 14 tests (7 `ehdb-l0` integration, 3 `ehdb-reference` unit,
4 `ehdb-stream`). RED→GREEN from a green baseline, three planted defects:
`FRAME_HEADER_LEN` 12→13 in `ehdb-l0` (3 of 7 fail), the same in the duplicate
constant (2 of 3 fail), and removing `deny_unknown_fields` (1 of 4 fail). All
reverted, all green again. ⛔ Not merged; kind/test only, no prod.
