# cmdbus-writer: the tier service and the engine lock

The `noetl-worker` binary has a second role beyond the pull loop. With
`NOETL_COMMAND_BUS_HOST=true` and `NOETL_EVENT_BUS_HOST=true` it becomes the
**writer** — in prod, the single StatefulSet pod `noetl-cmdbus-writer-0` that
hosts the command bus, the event bus and the EHDB tier service together.

This page records two facts about that role that are not obvious from the code
and cost a production diagnosis to establish
([noetl/ai-meta#351](https://github.com/noetl/ai-meta/issues/351), 2026-09-22).

## 1. The lag endpoint shares a lock with the data path

`:9102/metrics` is the command-bus lag face — the KEDA scale signal. It is not
a plain counter read. It also samples the D1 durability window, and to do that
it **takes the engine lock**. The endpoint publishes whether it managed to:

```
# HELP ehdb_l0_durability_sample_ok Whether this scrape sampled the durability
#      window (1) or could not acquire the engine lock (0).
ehdb_l0_durability_sample_ok 1
```

So a slow tier operation holding that lock blocks the scrape, and the scrape's
client sees a connection that was accepted and then never answered. KEDA
(3s timeout, 10s poll) reports this as:

```
context deadline exceeded (Client.Timeout exceeded while awaiting headers)
```

which reads like an unreachable endpoint and is not one.

**The same lock is in the path of the server's command- and event-bus calls.**
The server points `NOETL_COMMAND_BUS_WRITER_ADDRS` and
`NOETL_EVENT_BUS_WRITER_ADDRS` at this one pod, so when a tier operation stalls,
the server's own HTTP surface stalls with it — including request paths that
never touch the bus at all. On 2026-09-22 that reached the SPA as a hung UI,
with `/api/auth/validate` (a Postgres lookup) taking 16–68s.

Measured on prod, worker `6.1.6`, from one `:9090/metrics` scrape:

| `tier_service` op | count | mean | >1s | tail mean |
| :-- | --: | --: | --: | --: |
| `read_execution` | 7086 | 5.587s | 15.3% | **~36.4s** |
| `append` | 2607 | 2.217s | 12.1% | ~18.1s |
| `append_batch` | 593 | 3.774s | 11.8% | ~31.8s |
| `scan` | 1 | **75.92s** | 100% | 75.9s |
| `health` | 367 | **0.000376s** | 0% | — |

**`health` against `read_execution` is the diagnostic pairing.** Both are served
by the same process on the same listener; 0.38ms next to 5.6s says the control
path is fine and the data path is contended. Reach for that comparison before
concluding a writer pod is sick — a stalled writer and a saturated one look
identical from outside, and six plausible external theories (disk full, DNS, CPU
throttling, cold cache, an autoscaler feedback loop, node pressure) were all
wrong on the way to it.

Saturation shows up in the connection outcomes, against
`NOETL_EHDB_TIER_MAX_INFLIGHT` (4 in prod, `max_waiters=32`,
`shed_after_ms=1000`):

```
tier_service.conn  accepted=10656  closed=9751
                   shed_busy=805  shed_waiters_full=68  write_error=901
```

16.6% shed or failed. Averaged over the pod's life the tier ran at ~41% of its
inflight capacity, so the shedding is bursty and concentrated in the stall
windows rather than a steady overload.

## 2. The writer's probes cannot see any of this

The deployed StatefulSet uses **TCP-only probes, for liveness as well as
readiness**, and points both at the claim port rather than at any of the faces
that stall:

```yaml
livenessProbe:  { tcpSocket: { port: cmdbus-claim }, timeoutSeconds: 1,
                  periodSeconds: 20, failureThreshold: 3 }
readinessProbe: { tcpSocket: { port: cmdbus-claim }, timeoutSeconds: 1,
                  periodSeconds: 5,  failureThreshold: 3 }
```

A listening socket answers a TCP probe whatever the process is doing behind it.
So the writer stays `Ready` with `Restart Count: 0` through stalls of any
duration — the 2026-09-22 incident ran **18 hours** without alerting anyone, and
was found only because a user reported a hanging UI.

⚠ **Do not "simplify" these to match — they are already the weak form.** The
binary serves `/healthz`, `/readyz` and `/livez` on `:9090`
(see [deployment-specification](deployment-specification)); the writer's probes
should use them. This is the same defect class as
[noetl/ai-meta#322](https://github.com/noetl/ai-meta/issues/322), which found a
TCP readiness probe weaker than its HTTP liveness probe on the system pool —
here *both* are TCP, on the pod that carries both buses.

## What to watch

| signal | where | means |
| :-- | :-- | :-- |
| `ehdb_l0_durability_sample_ok` | `:9102`, `:9106` | `0` = the scrape could not take the engine lock; the numbers beside it are stale |
| `noetl_ehdb_tier_service_duration_seconds{operation}` | `:9090` | compare `health` against `read_execution`; a widening ratio is contention |
| `noetl_ehdb_dataplane_ops_total{outcome="shed_busy"}` | `:9090` | rising = past `NOETL_EHDB_TIER_MAX_INFLIGHT` |
| `ehdb_feed_subject_lag{subject}` | `:9102` | **per-pool**, so read the right subject: `commands.shared.*` is the user pool, `commands.system.*` the system pool. They diverge. |

That last row is worth its own warning. On 2026-09-22 `commands.shared.shard.0`
sat at 0 for a full day while `commands.system.shard.0` climbed past 600. Read
only the total (`ehdb_feed_total_lag`) or only the pool you expected, and you
will attribute a backlog to the wrong pool and size the wrong deployment.

## Related

- [deployment-specification](deployment-specification) — ports, probes, and the
  `NOETL_EHDB_*` / `NOETL_COMMAND_BUS_*` / `NOETL_EVENT_BUS_*` catalogue.
- [noetl/ai-meta#351](https://github.com/noetl/ai-meta/issues/351) — the
  diagnosis this page comes from, with the full evidence chain.
- [noetl/ai-meta#322](https://github.com/noetl/ai-meta/issues/322) — probe
  weakness on the system pool.
- [noetl/ai-meta#344](https://github.com/noetl/ai-meta/issues/344),
  [#343](https://github.com/noetl/ai-meta/issues/343) — tier batch append and
  frame cap.
- [noetl/ai-meta#318](https://github.com/noetl/ai-meta/issues/318) — the system
  pool has no autoscaler, which is what the `commands.system` backlog lands on.
