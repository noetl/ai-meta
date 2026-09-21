# Prod deploy of the durable writer fix — shipped, and the burst proof FAILED

**2026-09-21.** Honest headline: **the fix is deployed and dispatch is healthy,
but it did NOT prevent the OOM under a reconnect burst.** Do not treat this as
resolved.

## What shipped

| | |
| :-- | :-- |
| ehdb | **v0.3.1** (`forget_runtime`) |
| worker | **v6.1.2** (seal + burst bound) → **v6.1.3** (+ release sealed segments after read) |
| deployed | writer STS + all three worker pools, **by digest** `sha256:b38ce1e4…` |
| writer limit | 8 Gi → **12 Gi** (the agreed safety net) |
| knobs armed | `NOETL_EHDB_TIER_SEAL_MAX_BYTES=268435456` (256 MiB), `NOETL_EHDB_TIER_MAX_INFLIGHT=4` |

Rolled single-writer throughout (`replicas=1`, `RollingUpdate`), **no scale-down**,
**no tier-data deletion**, worker pools at `maxSurge=0`. Roll entered on a
verified near-zero in-flight window (`started=41` vs `completed=42`).

The burst bound **is** armed and confirmed in the log:
`EHDB tier service: concurrency bounded … max_inflight=4`.

## ❌ The burst proof failed

Rolling the worker pools *is* the mass-reconnect, and it is the same event that
OOMed the writer yesterday. It OOMed again:

```
burst start        22:13:25Z
container died     22:13:33Z   OOMKilled, exitCode 137   <- 8s later, at 12 GiB
container restart  22:13:38Z
```

⚠ My own first reading of this was wrong: a `kubectl top` sample of `2947Mi` at
22:13:40 looked like "memory fine" but was a **stale metric from the container
that had already died**. The restart count and `lastState` are what settled it.
A 15-second sampling interval cannot see an 8-second spike — *memory sampling is
not a substitute for the restart/termination record.*

From a ~2.9 GB baseline to >12 GiB in 8 seconds.

## Why the fix did not engage

**The seal never fired.** It triggers on an *append*, and **no tier append has
occurred at all** — the tier files are unmodified since 22:00, and the server
logged **0 projection-mirror attempts in 20 minutes**. So:

- the ~2.9 GB baseline is untouched (it is loaded on the **read** path at
  startup, not by appends);
- with a ~2.9 GB resident state, `max_inflight=4` still permits ~11.6 GB of
  concurrent copies — `4 × 2.9 + 2.9 ≈ 14.5 GB > 12 GiB`, which matches the
  observed kill almost exactly.

So the bound is correctly armed and simply **not tight enough while the state is
still multi-GB**, and the thing that would shrink the state cannot trigger.

⚠ And the arithmetic above implies the burst allocation is consistent with tier
appends — yet no tier appends are happening. That contradiction is **not
resolved**: the allocation may be in the bus reconnect path (command bus /
events feed), which neither change touches. I have not proven which, and I am
not going to assert one.

## Current state — stable, and not worse than before

All pods on v6.1.3 and healthy: **321 events / 5 min**, **0** claim-connect
failures on all workers, writer stable for 11+ minutes since the restart at
2922 Mi / 12 Gi, `restarts=1` (that one burst).

Before this deploy the writer was OOMing roughly every two hours at 8 Gi. It is
not worse. **No rollback performed**, because the state is better, and both new
knobs are inert here rather than harmful.

## What actually needs to happen next

1. **Determine what allocates on reconnect.** The tier is idle, so the
   multi-GB transient is probably not the tier. Until that is measured, tuning
   the tier bound is guessing.
2. **Make the seal reachable without depending on appends** — e.g. seal on open
   when the active segment is already over the bound. Today a store that is
   never appended to can never be sealed, which is exactly production.
3. Only then re-run the burst proof.

## Projector shadow soak — coverage still 0%, still NOT flip-ready

Projector confirmed **OFF** everywhere. 25-minute window:

| | value |
| :-- | --: |
| **denominator** — distinct executions | **12** |
| events persisted | 691 |
| projection-mirror attempts | **1** |
| attempts that succeeded | **0** |
| coverage | **0%** (1 of 12 executions even attempted) |
| cross-store parity samples | 74 |
| samples yielding a usable verdict | **0** (all `ehdb_unavailable`) |
| projection-parity verdicts | **0** |

The blocker changed shape but not conclusion: yesterday the mirror timed out;
today it is **not being attempted at all**. Either way the population the mirror
was offered is ~1 execution, so a divergence number would be meaningless.
Reporting "0 divergences" from this would be the vacuous pass.

**Do not flip the projector.**
