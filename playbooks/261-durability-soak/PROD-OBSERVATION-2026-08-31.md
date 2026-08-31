# The D1 durability window, observed on production

**2026-08-31. Bounded synthetic burst, owner-authorised. Read-only apart from the
executions themselves; nothing was flipped, nothing serves from a tier.**

## What was unprovable before

`ehdb_l0_unreplicated_age_seconds` read **0.000 forever** on an idle cluster.
That is indistinguishable from a metric that cannot fire — the exact
reachability trap this repo keeps finding. The 5-second age-seal bound was
*asserted* from the code and from a kind soak, never seen on production.

## Setup

| | |
| :-- | :-- |
| target | prod `noetl-server-rust`, version **3.97.1** (gate: `--expect-version 3.97.1`) |
| playbook | `test/simple_loop` v4 — pure Python arithmetic over a 3-item literal list; no external calls, no DB writes, no credentials |
| plan | 2/s for 90s, concurrency 4 |
| actual | **180 submitted**, 168×200 + 12 timeouts, 324.8s wall |
| config under test | `NOETL_EHDB_SEAL_MAX_AGE_MS=5000` on `noetl-cmdbus-writer-0` |

The version gate is not ceremony: a port-forward fails open, so the tool proved
it was talking to 3.97.1 (prod) and not 3.91.1 (kind) before sending anything.

## Result 1 — the age-seal bound is REAL and holds

Sampled every ~3s for 200s across both L0 engines:

```
t=0..37s    age 0.000, records 0          <- idle: the window is shut
t=40s       age 0.945, records 5          <- load arrives, window opens
t=43s       age 4.176, records 102
t=46s       age 2.424, records 157        <- seal fires, age resets
t=53s       age 3.833 ...  sawtooth continues for the rest of the run
```

- **43 of 60 samples non-zero.** Before the burst, every sample was 0.
- **eventbus max 5.251s, cmdbus max 5.837s** against a 5000 ms setting.
- The shape is a **sawtooth that repeatedly returns to 0** — records accumulate,
  age climbs toward 5s, the sweep seals and uploads, age drops. That is the
  age-seal working, not merely present.
- Unreplicated records peaked at **157** and drained to 0.

⚠ The bound is **≈5s + one sweep interval, not a hard 5.000s ceiling**. The
sweep runs on a timer, so the age can overshoot by up to one period before
sealing — 5.25s and 5.84s are that overshoot, not a violation. Anyone alerting
on this should threshold above 5s, not at it.

## Result 2 — catalog verify agrees, 180/180

```
noetl_catalog_relation_read_total{operation="get_latest",outcome="agree"}   +180
noetl_catalog_relation_read_total{...,outcome="disagree"}                     +0
noetl_catalog_read_served_total{served_by="incumbent"}                      +180
noetl_catalog_read_served_total{served_by="relation"}                         +0
```

Perfect agreement across 180 reads, and the incumbent served every one — verify
mode behaving exactly as designed. **This is evidence for a future tier flip; it
is not a flip, and none was made.**

## Result 3 — ⚠ load produces TRANSIENT cross-store divergence

```
noetl_ehdb_crossstore_divergence_total{kind="missing_event",tier="eventlog"}  +9
noetl_ehdb_crossstore_divergence_total{kind="count",tier="eventlog"}          +9
noetl_ehdb_crossstore_divergence_total{kind="order",tier="eventlog"}          +6
noetl_ehdb_crossstore_events_compared_total{tier="eventlog"}                 +86
```

These stopped incrementing the moment load stopped and have not moved since, so
they are **in-flight artefacts**: the comparator sampled executions whose events
had not finished mirroring. Not corruption — a race between the comparator and
the mirror.

**Why it matters anyway:** those counters are what the EHDB parity alert reads
(cf. ai-meta#264, where the parity endpoint writes the counter its own alert
consumes). A load burst therefore *manufactures* alertable divergence. Any
paging rule on `crossstore_divergence_total` needs a settle window or a
rate-over-time condition, or the first busy period will page on nothing.

## Health — no abort criterion tripped

| | before | after |
| :-- | --: | --: |
| `noetl-cmdbus-writer-0` restarts | 0 | **0** |
| `noetl-server-rust` restarts | 0 | **0** |
| worker restarts | 0 | **0** |
| `system-pool-shard1` restarts | 6 | **6** (unchanged, pre-dates today) |
| pgbouncer restarts | 0,0 | **0,0** |

The **12 timeouts are not a fault**: the burst created backlog, KEDA scaled the
user pool from **2 to ~20 pods**, and cold starts exceeded the 30s client
timeout. pgbouncer scaled to 2 as well. The platform absorbed the load and
autoscaled — which is itself an observation worth having.

## What this does NOT license

The tier still serves nothing. Event-log stays primary, catalog stays on
`verify`, #307 stays on `verify`. Agreement under one 180-execution burst is
evidence, not a mandate; the serve-flips remain held for the owner.
