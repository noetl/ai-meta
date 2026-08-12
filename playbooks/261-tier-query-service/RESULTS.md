# ai-meta#257 PR 4 — gate results

Run 2026-08-12, kind cluster `kind-noetl`, **three worker replicas**, on built
images. Worker branch `feat/257-pr4-tier-query-service` @ `7fd7e42`, server
branch `feat/257-pr4-tier-query-service` @ `2206728`, both stacked on
`feat/258-server-authored-mirror`.

## Images

| tag | image id | source |
| :-- | :-- | :-- |
| `localhost/noetl-worker:pr4real` | `6f717f502dea` | committed tree @ `19862ca` |
| `localhost/noetl-worker:pr4mut` | `47027e55b4e9` | same + `mutation.patch` |
| `localhost/noetl-server:pr4real` | `f2fa90c38021` | committed tree @ `2206728` |

Distinct ids for real vs mutated confirm the mutation reached the binary rather
than being silently ignored. Both were verified present in the kind node by name
before arming (`deploy.sh load` fails if fewer than two `pr4real` images land).

## Topology

Worker pool pinned at **3 replicas**, writer at 1 hosting the tier service on
`:9110` with its store on the PVC at `/data/eventbus/tier`. The tier service was
up in **both** arms, so the arms differ in exactly one variable:
`NOETL_EHDB_TIER_QUERY_SOURCE`.

> **Pinning 3 replicas needs the KEDA annotation, not `kubectl scale`.**
> `noetl-worker-rust` carries a ScaledObject with
> `autoscaling.keda.sh/paused-replicas: "0"`, which reverts a manual scale within
> seconds — and a 0-replica Deployment reports **"successfully rolled out"**. The
> first arming attempt therefore looked entirely successful and left the pool at
> zero. `deploy.sh` now sets `paused-replicas=N` and asserts `readyReplicas`
> before returning.

## Arm `local` — the failure the single-replica gate could not see

```
=== arm local: 17 passed, 0 failed ===
```

Per-replica direct reads, by pod IP (bypassing the Service, so "which replica
answered" is controlled rather than raced):

| replica | records | `tier_query_source` |
| :-- | --: | :-- |
| 10.244.0.37 | **0** | local |
| 10.244.0.39 | **13** | local |
| 10.244.0.38 | **0** | local |

And the comparator, with the relay pinned at each pod in turn:

| relay pinned at | outcome | ehdb / auth | divergence kinds |
| :-- | :-- | --: | :-- |
| 10.244.0.37 | **divergent** | 0 / 13 | `missing_event`, `missing_execution` |
| 10.244.0.39 | **match** | 13 / 13 | — |
| 10.244.0.38 | **divergent** | 0 / 13 | `missing_event`, `missing_execution` |

**One execution, three answers.** The server mirrored all 13 events through one
relay hop, that hop resolved to one pod, and the other two hold nothing for the
execution at all. Two thirds of reads report the tier as empty; one third
reports a clean full-set match.

This is what #258's single-replica gate was structurally unable to observe, and
it is why its `13 == 13` is true but insufficient: at three replicas the same
measurement had a **1-in-3 chance** of reading the full set and declaring
success. Prod runs multiple replicas.

## Arm `service` — one store, whichever replica is hit

```
=== arm service: 22 passed, 0 failed ===
```

| replica | records | `tier_query_source` |
| :-- | --: | :-- |
| 10.244.0.47 | 13 | service |
| 10.244.0.49 | 13 | service |
| 10.244.0.50 | 13 | service |

| relay pinned at | outcome | ehdb / auth | holds |
| :-- | :-- | --: | :-- |
| 10.244.0.47 | match | 13 / 13 | true |
| 10.244.0.49 | match | 13 / 13 | true |
| 10.244.0.50 | match | 13 / 13 | true |

Plus the full-set assertions from #258, unchanged: `unmirrored_by_design = 0`,
`matched == authoritative_count = 13`, `divergences = 0`, `holds = true`, and
the in-binary comparator controls clean before and after (`controls_ok=true`,
`unexpected=0`, `expected=8`).

The pod-local stores are **empty** in this arm — nothing was written to them —
so the tier is one store by construction, not by luck of routing.

## Mutation check 1 — environment: the read really leaves the pod

`0 records everywhere` is also what a *broken* service returns, so the arm alone
cannot separate "reads the service" from "falls back to a coincidentally-empty
local store". `mutation.sh` constructs the state that does, **without restarting
a worker** (a `set env` flip would roll the pods and wipe the pod-local store,
leaving the test measuring empty against empty):

1. copy the writer's tier store into **every** replica's
   `NOETL_EHDB_LOCAL_REFERENCE_LOG` — now a fall-back would find the data;
2. truncate the writer's tier store — now the service has nothing.

```
   /data/eventbus/tier/eventlog.jsonl: 26 records -> 0
   seeded 3/3 replicas at /tmp/ehdb/ref.jsonl
```

Result — `=== arm mutated: 15 passed, 0 failed ===`

| replica | records | source |
| :-- | --: | :-- |
| all three | **0** | service |

Verdict `divergent` (0/13) from every replica. The records were sitting in the
pod-local store on the same pod and were not returned. The read resolves through
the service.

## Mutation check 2 — code: a compiling defect the gate must catch

`mutation.patch` reinstates the silent fall-back in its most dangerous form: the
service branch falls through to the pod-local read **while still reporting
`tier_query_source: service`**. It compiles; the image id differs.

**Against the `service` arm** — `=== arm service: 15 passed, 7 failed ===`

The seven failures are exactly the ones carrying the claim:

```
  FAIL  and that view is the full set — got '0', want '13'
  FAIL  no replica is short — got '3', want '0'
  FAIL  one verdict, whichever replica is reached — got 'divergent', want 'match'
  FAIL  one tier count, whichever replica is reached — got '0', want '13'
  FAIL  matched == authoritative total — got '0', want '13'
  FAIL  divergences — got '2', want '0'
  FAIL  holds — got 'false', want 'true'
```

**and `every replica reports source=service` still PASSED.** That is the point of
the design: the label is necessary for attribution but is not sufficient as
evidence, because a defect can keep the label honest-looking while changing the
bytes. The data assertions are what discriminate.

**Against the seeded state** (pod-local holds the records, service is empty) the
mutated binary produced the worst possible reading:

| relay pinned at | outcome | ehdb / auth | holds | source |
| :-- | :-- | --: | :-- | :-- |
| all three | **match** | **13 / 13** | **true** | service |

A clean full-set match, zero divergences, `holds: true` — **against a tier
service whose store is empty**. Nothing in that verdict is distinguishable from
success except the two checks this gate adds, both of which failed:

```
  FAIL  3 replica(s) returned the full set from an EMPTY tier service —
        the read silently fell back to the pod-local store
  FAIL  verdict stayed 'match' against an EMPTY tier service
```

**Restoring `pr4real` returned the service arm to 22 passed / 0 failed**, so the
failures are attributable to the mutation and not to drift in the cluster.

## Two findings the run produced

**1. The tier service's startup line described a build two PRs old.** The writer
logged `EHDB tier service listener up (skeleton: health only, serves no tier
data)` while serving 26 records. True at PR 1, false since PR 3, and it is the
one line an operator would read to answer "can this writer serve the tier?".
Nothing forced it to agree with the code and no test reads a log line. Fixed in
worker `7fd7e42` — it now reports the store path (or `<none: data ops answer
\`unavailable\`>`) rather than asserting a capability, so there is no sentence to
go stale when the op set grows again.

**2. A relay pinned at a dead pod IP is reported, not scored.** After an image
swap replaced the pods, the parity endpoint returned
`outcome: "ehdb_unavailable"` naming the failed URL — not an empty record set
scored as agreement. The fail-loud posture holds under a real failure, which is
the first time it has been exercised by one rather than by a control.

## Harness bugs found and fixed (not product defects, recorded so they are not re-hit)

* **The settle loop latched mid-flight.** Two stable polls declared an execution
  settled at 6 events; it went on to write 13. Now requires six consecutive
  stable polls and a floor of 10, and the expected count is **derived** from the
  settled authoritative count rather than hardcoded — this cluster wrote 13, and
  pinning a literal would fail on a difference that is not the thing under test.
* **`kubectl rollout status` returning ≠ the endpoint serving.** The old server
  pod answers `/api/health` with 200 while terminating, so a single probe passed
  and the next request landed in the gap, producing empty bodies that every
  assertion then reported as a failure of the product. `wait_server` now requires
  one Running pod and three consecutive 200s.
* **`mapfile` does not exist in macOS bash 3.2** — the replica array would have
  stayed silently empty, aborting with what looks like a topology problem.

## State left behind

Kind restored to released images with zero EHDB env:

```
noetl-server-rust      ghcr.io/noetl/server:3.79.2
noetl-worker-rust      ghcr.io/noetl/worker:5.115.3-arm64   (0 replicas, KEDA paused-replicas=0)
noetl-cmdbus-writer    ghcr.io/noetl/worker:5.115.3-arm64
```

`NOETL_EHDB_WORKER_QUERY_URL` on the server is the value that was there before
this session, restored deliberately. No other `NOETL_EHDB_*` remains on any
workload.

⚠ The writer's PVC still holds `/data/eventbus/tier/eventlog.jsonl` with the
last arm's 13 records. It is inert — no listener, `NOETL_EHDB_TIER_SERVICE_BIND`
is unset — but a future `mutation.sh` will count them in its "before" figure.

**No prod change of any kind. No tier promoted to `primary`. No
`NOETL_EHDB_TIER_*` set on prod. Nothing pushed** — see `PENDING-PUSH.md`.
