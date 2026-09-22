# Prod incident: the writer cannot complete startup registration — and it is NOT the index change

**Open as of 2026-09-22 08:30Z. Dispatch is degrading. Needs an owner decision.**

## What is happening

`noetl-cmdbus-writer-0` restarts about every 2.5 minutes. Each time it exits:

```
ERROR noetl_worker: Worker error
  error=error sending request for url
  (http://noetl-server-rust.noetl.svc.cluster.local:8082/api/worker/pool/register)
Caused by: operation timed out
```

Registration failure is fatal, so the process exits 1 and the container restarts.

## ⚠ It is not the index change — the rollback loops identically

I rolled the writer to **v6.1.5** (the index fix) at 07:55Z; it began looping. I
rolled it **back** to the exact pre-session image
(`sha256:b38ce1e4…`) at 08:10Z and it looped on the same ~2.5-minute cadence —
restarts 1, 2, 3, 4, 5. **Both images fail the same way**, so the trigger is
*restarting the writer at all, with the current data volume*, not the binary.

Two further checks that exonerate the index work:

- The backfill runs **once**: `segment has no index; building it` appears **0**
  times in the six minutes spanning restarts 2 and 3, because the `.idx` files
  already exist. Restarts 2+ do no index work at all and still fail.
- The backfill that *did* run was cheap: 1.08 GB indexed in 5.6 s and 3.3 GB in
  31 s, with process peak RSS **1.19 GB** against a 12 Gi limit (the pre-roll
  peak was 4.0 GB).

## Why registration times out — the mechanism

The server is healthy and reachable. The stable `noetl-worker-rust` pods
(restarts=0, 8 h old) show **zero** heartbeat or registration failures over the
same window, and the `noetl-server-rust` Service endpoint (10.119.0.94:8082)
matches the server pod IP with a matching selector.

What is specific to the writer is its startup. Measured on the rolled-back
image:

| | |
| :-- | --: |
| start | 08:21:55 |
| command-bus up | +0.3 s |
| **events-feed engine opened** | **+28 s** |
| three group resumes | +13 s each |
| KV up | +69 s |
| registration times out | **+135 s** |

Those long steps are blocking work on the same async runtime the HTTP client
runs on. Starving the reactor makes the registration call miss its (hardcoded,
no env knob) timeout even though the server answers everyone else promptly. The
writer's store has grown enough that the starvation window now exceeds it.

## Blast radius — dispatch is degrading, data is intact

The writer hosts the command-bus claim coordinator (`:9101`), so while it is
down nothing can claim:

| window | issued | started | completed |
| :-- | --: | --: | --: |
| last 60 min | 83 | 101 | 98 |
| last 30 min | 77 | 58 | 56 |
| **last 5 min** | **17** | **5** | **6** |

A backlog is accumulating. There is a second loop: each writer restart makes the
system pool fail `claim connect` to `:9104`/`:9108`, and
`noetl-state-builder-watchdog` (a ServiceAccount, not a person) then patches
`noetl-worker-system-pool` — it did so twice at 08:00Z. `…-shard1` reached
CrashLoopBackOff with 8 restarts.

⚠ **No data loss.** Every tier segment is byte-identical and none was deleted:
`eventlog.jsonl.1` 1,085,472,212 bytes and `projection.jsonl.1` 3,301,113,835
bytes, both still dated Sep 21 22:00. The only additions are the two `.idx`
sidecars (18 KB and 5 KB), which an older binary ignores.

## What I could not do

Raising the writer's CPU (2 → 4) to shorten the blocking startup below the
registration timeout is the cheapest mitigation with a real mechanism, and it is
reversible. **The permission layer refused the patch**, and I did not work
around it.

## Options, for the owner

1. **Raise the writer's CPU limit** (reversible, one restart). Directly targets
   the measured mechanism.
2. **Make registration non-fatal / retried** rather than an exit, and move the
   blocking startup work off the async runtime. This is the real fix and it is a
   code change in `worker.rs` / `client/control_plane.rs`; the timeout is
   hardcoded, so there is no config lever today.
3. **Quiesce the state-builder watchdog** while the writer is unstable, to stop
   the second loop amplifying the first.

Option 2 is the durable one; option 1 is what would stop the bleeding now.
