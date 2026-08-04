# Permanent-log-lean strip — kind validation of BOTH halves (#195 + #196)

**Verdict: PASS on both halves and on the safety property. Still default-off
everywhere, in kind and in prod. Nothing was enabled beyond the run.**

Date: 2026-08-04 · context `kind-noetl` · server `noetl-server-rust`

---

## What was actually being asked

One flag, `NOETL_PERMANENT_LOG_LEAN`, strips two different things through the
same call site in `permanent_log_lean.rs`. The second is the larger:

| | what it strips | measured on prod |
| :-- | :-- | :-- |
| **D1** (#195) | over-floor step **results** → `reference` + `extracted` | 461 MB |
| **D2** (#196) | over-floor command **contexts** → `__context_ref__` | 1229 MB |

An earlier version of this rig asserted D1 only, which left 73% of the change
unvalidated.

---

## Results

| assertion | result |
| :-- | :-- |
| **effect** | `noetl_permanent_log_slimmed_total` 0 → 2, `…_bytes_total` 0 → 22,633 |
| **D1 shape** | over-floor `call.done` result: **773 bytes** persisted, carrying a `reference` |
| **D2 shape** | **1 of 1** `command.issued` rows tiered; persisted context **150 bytes** (~18.7 KB externalised) |
| **negative control** | sub-floor scalar: 353 bytes, **0** reference rows, **0** `__context_ref__` rows — the floor holds in both halves |
| **readable** | reading the execution back through the API returns `customer-0059` — `hydrate_result_references` resolves it |
| **drive** | both executions `COMPLETED` |
| **D2 safety claim** | peak **2** live `noetl.command` rows carrying a full context during the run |

The last row is the one that matters for #196. `permanent_log_lean.rs` argues
stripping a command's context is safe because *"apply_event reads only
node_name + meta.cursor for a command.issued event, and the transient
noetl.command row still holds the full context for a claim that reads it before
materialization."* Both halves were checked rather than trusted: the execution
completed (the drive advanced without the stripped context) **and** the
transient row was observed still carrying it while the command was live.

---

## Two things this run corrected in the rig itself

**1. The D2 half needs a large INPUT, and the fixture had a large OUTPUT.**

`tests/195/big_result` produces an ~8 KB result from an empty `workload`, so its
`command.issued` context is ~150 bytes — *under* the floor. D2 correctly stripped
nothing, and the rig reported `FAIL(d2-shape)` for a playbook that was never
eligible. Fixed by adding `tests/195/big_input`, which carries the payload on the
way **in**.

This is the same shape as the six inert gates in
[`inert-gate-audit-20260804.md`](../inert-gate-audit-20260804.md): a measurement
that returns a confident zero for a reason unrelated to the thing being measured.
Here the *fixture* was ineligible rather than the *gate* unreachable, but the
reading is identical and equally wrong.

**2. The port-forward race, for the third time this session.**

The first attempt returned empty execution IDs and six FAILs. The cause was
entirely mechanical: the rig killed its forward, slept 1s, and re-forwarded at a
pod that was still rolling. Every fire got nothing.

`pf()` now waits for `condition=Available` and then polls `/health` until it
answers, and **exits 3 rather than reporting a verdict** if the server never
becomes reachable — a measurement failure must not be able to present itself as a
result about the strip.

---

## What this does NOT say

- It does not say the strip should be **enabled**. It says enabling it is safe on
  the axes tested. The enable decision is parked with the user, together with the
  fact that the flag is **forward-only**: it changes what gets written from the
  moment it is on and reclaims none of the **1689 MB (59% of the permanent log)**
  already there. There is no backfill or reclamation mechanism today.
- Scale: this ran two executions in kind. It proves shape, floor, readability and
  drive-safety, not behaviour under prod volume.

---

## Reproduce

```bash
./playbooks/195-lean-log/validate-lean-strip.sh   # enables, asserts, restores default-off
```

Confirmed restored: `PERMANENT_LOG_LEAN refs remaining: 0`.
