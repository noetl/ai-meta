# Projection tier (tier 2) — prod cutover runbook

**Status: PREPARED, NOT EXECUTED.** Nothing in this file has been run against
production. Every step past §3 needs an explicit per-step go from the owner.

**Tracks:** [ai-meta#265](https://github.com/noetl/ai-meta/issues/265) ·
Companion to `GAP-ANALYSIS.md` and `RESULTS.md` (phase A) / `RESULTS-B1.md` (read-serve).

---

## 0. The hard constraint

The **event-log tier (tier 1) is `primary` and serving in production.** Nothing
in this runbook touches it. `NOETL_EHDB_EVENTLOG` is not read, not written and
not restarted by any step here. If a step appears to require moving it, the step
is wrong — stop.

## 1. What "cutover" means for this tier, precisely

Three separate flags, three separate decisions, and they are **not** one switch:

| flag | what turning it on does | reversible by |
| :-- | :-- | :-- |
| `NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server` | the server appends every authoritative snapshot into the tier. **Write-only.** Nothing reads it. | unsetting it |
| `NOETL_EHDB_PROJECTION_PARITY_ENABLED=true` | the comparator scores tier vs incumbent. **Read-only, no serve effect.** | unsetting it |
| `NOETL_EHDB_PROJECTION_READ_SOURCE` | `postgres` (default) → `verify` → `tier`. **This is the only flag that changes what a caller receives.** | setting it back |

`NOETL_EHDB_PROJECTION=shadow\|primary` is a *fourth*, worker-side, and it is
already `shadow` on prod. It governs the write path's serve decision, not any
read. Note this explicitly: **prod already sets `NOETL_EHDB_PROJECTION=shadow`**
— the 2026-08-14 gate exit note claiming no `NOETL_EHDB_PROJECTION*` variable
existed on prod was wrong.

## 2. The amplification hazard that shapes the ordering

`POST /api/internal/projection/advance` — the route the `system/projector`
playbook calls — does `rebuild_state` **then** `orch_snapshot::save`. In `tier`
mode that means:

> the tier's snapshot becomes an **input** to the incumbent's next snapshot.

A wrong tier snapshot that got served would be folded forward and written back
into `noetl.projection_snapshot`, making the incumbent wrong too — and the
comparator would then report `match`, because both stores agree on the corrupted
value.

`verify` mode cannot do this: it compares against the incumbent before serving,
so a tier that disagrees is never the input. **This is why `verify` is not an
optional intermediate step.** `tier` mode is only defensible after a soak in
which `verify` served a high fraction of reads with zero fault-class demotes.

## 3. Preconditions — all must hold before step 4

| # | precondition | how to check | status |
| :-- | :-- | :-- | :-- |
| P1 | server ≥ the release carrying #355, worker ≥ v5.121.0, both **deployed** | `kubectl -n noetl get deploy -o jsonpath` on the image digests | ⬜ not deployed |
| P2 | the read-serve kind gate is green on built images, all arms | `RESULTS-B1.md` | ⬜ |
| P3 | `ops` manifests declare all four env vars, and the deployment-spec wiki pages carry them | ops PR + wiki diff | ⬜ **not done — G5** |
| P4 | tier-service address + store PVC exist for the prod writer | writer StatefulSet spec | ⬜ |
| P5 | the coverage denominator is readable on prod | `noetl_ehdb_projection_snapshot_gate_total` present | ⬜ (ships with #355) |
| P6 | rollback rehearsed in kind: each flag off restores the previous behaviour within one rollout | gate `restore` arm | ⬜ |

P3 is a genuine blocker, not a formality: ai-meta#267 found prod IaC omitting 84
live env vars, so a variable set by hand is a variable a DR re-apply silently
removes.

## 4. Step C1 — arm the mirror (write-only). **Needs a go.**

```
NOETL_EHDB_PROJECTION_MIRROR_SOURCE=server
NOETL_EHDB_PROJECTION_PARITY_ENABLED=true
```

on `noetl-server-rust` only. The worker's `NOETL_EHDB_PROJECTION=shadow` and the
tier-service address must already be in place.

**What changes:** the server appends one record per snapshot upsert. Nothing
reads the tier. `orch_snapshot::save` gains a synchronous relay POST — see the
latency note in §7.

**Rollback:** unset the two variables; one rollout. The mirror only appends and
never touches `noetl.projection_snapshot`, so there is nothing to undo in the
incumbent.

**Watch:** `noetl_ehdb_projection_mirror_total{outcome}` — `mirrored` should
dominate; any `unconfigured` means the relay URL is missing and the tier is
silently empty.

## 5. Step C2 — soak, with a denominator. **No go needed; it is measurement.**

Minimum window: **7 days**, or until each of these is answerable:

1. **Coverage.** `noetl_ehdb_projection_snapshot_gate_total{outcome="written"}`
   over the sum of all outcomes. This is the fraction of orchestrator passes
   that produce a row at all. If it is near zero, a divergence count of zero
   says nothing and the soak has not started.
2. **Divergence.** `noetl_ehdb_crossstore_divergence_total{tier="projection"}`
   at 0 across the window, with
   `noetl_ehdb_crossstore_events_compared_total{tier="projection"}` non-trivial.
3. **Controls.** `noetl_ehdb_projection_control_total{result="unexpected"}` at 0
   and `{result="expected"}` moving — a comparator that cannot detect divergence
   reports zero divergence, and so does a healthy platform.

**Do not read "0 divergences" without (1) and (3) in the same breath.** That is
the vacuous pass this whole design was shaped around.

## 6. Step C3 — `verify` mode. **Needs a separate go.**

```
NOETL_EHDB_PROJECTION_READ_SOURCE=verify
```

This is the first step where a read can come from the tier. It cannot serve a
wrong answer: the incumbent is loaded first and the tier is served only on
agreement.

**Watch, per rollout:**

- `noetl_ehdb_projection_read_total{outcome="served_tier"}` climbing — if it
  stays at 0 the mode is inert and the cause is upstream (coverage, or the relay).
- the fault classes at 0: `version_ahead`, `checksum`, `divergent`, `unreadable`,
  `undeserialisable`. **`version_ahead` is the one that matters** — it is the
  only reason that means "serving would have been wrong", as opposed to "there
  was nothing to serve".
- `missing` / `no_incumbent` / `unconfigured` are **expected** and are not
  faults. `missing` is every execution that predates the mirror arming.

**Rollback:** `NOETL_EHDB_PROJECTION_READ_SOURCE=postgres`; one rollout; the read
path returns to a plain `SELECT` with no relay call.

**Abort immediately if** any fault-class counter moves. A single `version_ahead`
on prod means the tier claimed to have folded an event that does not exist.

## 7. Step C4 — G3, the async mirror. **Needed before `tier` mode, not after.**

The mirror is a synchronous awaited POST (5 s timeout) inside
`orch_snapshot::save`, and one of `save`'s callers is the inline orchestrator
self-write. This is the shape ai-meta#155 removed from the event-log mirror,
where it measured **78.6 ms → 0.1 ms per call** and moved the median warm Muno
turn 16.9 s → 13.0 s.

**Pairing discipline, non-negotiable and learned from #155:** an async mirror
requires a comparator lag-tolerance window
(`NOETL_EHDB_PROJECTION_PARITY_LAG_TOLERANCE_SECS`, the projection twin of the
event log's). **Set both or neither.** Async on with the window at 0 makes the
comparator judge a healthy tier on its own liveness and manufacture divergences.

Not yet built. Tracked as G3.

## 8. Step C5 — `tier` mode. **Needs a separate go, and §2 is the argument against rushing it.**

```
NOETL_EHDB_PROJECTION_READ_SOURCE=tier
```

Only after: C3 soaked with `served_tier` dominating and every fault class flat
at 0, over a window where the coverage denominator says the reads were real.

`tier` mode stops reading the incumbent on the serving path. It keeps the
`MAX(event_id)` probe — that is the ahead-check and it is what stands between a
crafted or corrupted record and a state that never existed.

**Rollback:** back to `verify`, then to `postgres`. Two rollouts, each one
variable.

## 9. What this runbook explicitly does not authorise

- Retiring `noetl.projection_snapshot`. Even with `tier` mode soaked, the
  incumbent stays: it is the demote target, and a tier with no fallback is not
  the same system.
- Any change to `NOETL_EHDB_EVENTLOG`.
- Turning on more than one flag per rollout. Every step above moves exactly one
  variable so that a regression is attributable.
- Disposition of the dead `noetl.projection` table (G7) — separate decision.
