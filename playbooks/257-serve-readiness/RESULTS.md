# ai-meta#257 — consolidated serve-readiness gate: results

Run 2026-08-12, kind cluster `kind-noetl`, **three worker replicas**, on built
images. This is the go/no-go evidence for promoting the EHDB event-log tier.

---

## Verdict

> **The serve-readiness bundle is GREEN. The flip itself is BLOCKED.**
>
> Composed at three replicas, the event-log tier holds the complete
> authoritative event set, every replica agrees, the serve path is observable
> while it happens, and the safety posture holds when the tier service dies.
>
> But `NOETL_EHDB_EVENTLOG=primary`, applied to **exactly that configuration**,
> changed nothing measurable: `served_primary = 0` on every replica — the whole
> `noetl_ehdb_eventlog_ops_total` family **absent** — while 13 events per
> execution flowed and landed correctly. On the server-authored,
> service-resolved path, `primary_serve::decide` has **no reachable caller**.
>
> A prod flip today would be inert, and — until worker `fix/259-primary-flip-signal`
> lands — would emit **no log line at all** saying so.

---

## Images

| tag | image id | source |
| :-- | :-- | :-- |
| `localhost/noetl-worker:capreal` | `885c115bdcb6` | composed tree @ `a87dd14` |
| `localhost/noetl-worker:capmut` | `db71eb32a8cc` | same + `mutation.patch` |
| `localhost/noetl-server:pr4real` | `f2fa90c38021` | server `2206728` |

Distinct ids for real vs mutated confirm the mutation reached the binary rather
than being silently ignored. `deploy.sh load` asserts each tag is present in the
kind node **by name** before arming — `kind load` has reported success for an
image the node did not end up with.

### The composition itself is new work

`feat/260-tier-service-metrics` (`dcd0266`) and `feat/257-pr4-tier-query-service`
(`7fd7e42`) are **separate lineages** off v5.115.3. **No build before this one
contained both.** `feat/257-serve-readiness` (`a87dd14`) is the cherry-pick;
`src/ehdb/metrics.rs` and `src/event_bus.rs` auto-merged and both sides survive
(#260's `pin_tier_service_series` call and PR 4's corrected startup line).

## Topology

Worker pool pinned at **3 replicas** via the KEDA `paused-replicas` annotation
(never `kubectl scale` — a ScaledObject with `paused-replicas: "0"` reverts a
manual scale within seconds, and a 0-replica Deployment reports *"successfully
rolled out"*). Writer at 1, hosting the tier service on `:9110` with its store
on the PVC at `/data/eventbus/tier`.

---

## Arm `service` — the evidence bundle

```
=== arm service: 41 passed, 0 failed ===
```

Per-replica direct reads, by pod IP (bypassing the Service, so "which replica
answered" is controlled rather than raced):

| replica | records | `tier_query_source` |
| :-- | --: | :-- |
| 10.244.0.83 | 13 | service |
| 10.244.0.81 | 13 | service |
| 10.244.0.82 | 13 | service |

And the comparator, with the relay pinned at each pod in turn:

| relay pinned at | outcome | ehdb / auth | holds |
| :-- | :-- | --: | :-- |
| 10.244.0.83 | match | 13 / 13 | true |
| 10.244.0.81 | match | 13 / 13 | true |
| 10.244.0.82 | match | 13 / 13 | true |

Plus `unmirrored_by_design = 0`, `matched == authoritative_count`,
`divergences = 0`, and the in-binary comparator controls clean before **and**
after (`controls_ok=true, expected=8, unexpected=0`).

**The observability moved on the right labels while this happened** — the part
no previous gate ran together with the data assertions:

| series | delta |
| :-- | --: |
| `tier_service.append/ok` | +13 |
| `tier_service.read_execution/hit` | +19 |
| `tier_service_duration_seconds_count{append}` | +13 |
| `tier_service_duration_seconds_count{read_execution}` | +19 |
| `tier_service_store_appends_total` | +13 |
| `tier_service_store_sequence` | +13 |

with `+Inf == count` for both operations and non-zero sums (`0.076258` /
`0.031403`) — a recorder firing with a hardcoded `0.0` would look alive and
measure nothing. Per replica, `noetl_worker_ehdb_query_ops_total{operation=
"tier_query_source.read",outcome="service"}` moved on all three.

---

## Mutation check — the bundle fails when it should, in **both** families

`mutation.patch` composes two compiling defects: the silent fall-back to the
pod-local store **while still reporting `tier_query_source: service`**, and the
dropped `record_tier_service` call for `append`.

```
=== arm mutated: 25 passed, 15 failed ===        exit status 1   (reproduced twice)
```

**Data family (7):**

```
  FAIL  and that view is the full set — got '0', want '19'
  FAIL  no replica is short — got '3', want '0'
  FAIL  relay->…: tier holds the whole authoritative set — got '0', want '19'   (×3)
  FAIL  ONE verdict, whichever replica is reached — got 'divergent', want 'match'
  FAIL  matched == authoritative total — got '0', want '19'
  FAIL  divergences — got '2', want '0'
  FAIL  holds — got 'false', want 'true'
```

**Metrics family (6):**

```
  FAIL  tier_service.append/ok — moved by 0, want >= 19
  FAIL  tier_service.read_execution/hit — moved by 0, want >= 1
  FAIL  latency histogram count{append} — moved by 0, want >= 19
  FAIL  latency histogram count{read_execution} — moved by 0, want >= 1
  FAIL  histogram sum{append} is '0.000000'
  FAIL  histogram sum{read_execution} is '0.000000'
```

**Two checks PASSED under the mutation, and that is the point of composing it:**

* `every replica STILL reports source=service` — the label stays honest-looking
  while the bytes come from another store. Attribution needs the label; evidence
  needs the data.
* `store_appends_total (+19)` — the append really happened and the store really
  grew. Only the request-path signal disappeared. A gate asserting "the store
  grew" passes this, which is precisely the invisibility #260 was filed about.

**Restoring `capreal` returned the same cluster to 41 passed / 0 failed**, so the
failures are attributable to the mutation and not to drift.

---

## Arm `primary` — the flip, rehearsed

```
=== arm primary: 44 passed, 1 failed ===
```

Everything the `service` arm asserts still held under `primary`: full-set match
13/13 from all three replicas, one verdict, observability moving. The single
failure is the finding:

```
  FAIL  served_primary is 0 across every replica while 13 events flowed —
        'primary' took no different branch on this configuration
```

Not zero — **absent**. `noetl_ehdb_eventlog_ops_total` rendered nothing at all on
any replica, in a build where the family exists.

### Why: two call sites, and this configuration reaches neither

| `primary_serve::decide` call site | why it is not reached |
| :-- | :-- |
| `eventlog::mirror_live_event` — the worker's own mirror hook | `MIRROR_SOURCE=server` disarms the hook in `client/control_plane.rs` **before** the tier mode is consulted, so `runtime_hook_env` — the only caller of the flip-time signal — never runs |
| `metrics_server::ehdb_tier_append_handler`, `Resolution::Local` branch | `TIER_QUERY_SOURCE=service` takes `Resolution::Service(client)`, which calls `client.append()` and never enters `mirror_event` |

Confirmed at the log level too: at flip time the worker pods emitted **no line
about the tier being primary** — not `primary_not_wired`, not anything. Only
the disarm notice:

```
NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server — the worker's event-log mirror is
disarmed; the server's write chokepoint mirrors the full authoritative set
```

This is the reachability lens, not the existence one: the serve path exists, is
registered, is tested, and is documented — and on the configuration that makes
the tier correct at multiple replicas, nothing calls it.

### The safety claim the rollback rests on, measured

Through the primary window, every execution left a **complete** set in the
incumbent — asserted structurally (`playbook.completed` present,
`command.issued == command.completed`) rather than as an equality against a
literal, because this probe writes 13, 19 or 22 events depending on whether its
trailing step ran:

| execution | events | `playbook.completed` | issued / completed |
| :-- | --: | --: | :-- |
| 345837788123369472 | 13 | 1 | 2 / 2 |
| 345837903122796544 | 13 | 1 | 2 / 2 |
| 345838017874759680 | 13 | 1 | 2 / 2 |

---

## Arm `killswitch` — the serve policy under composition

Tier-service face removed from the writer (`NOETL_EHDB_TIER_SERVICE_BIND` unset)
while every **other** writer face — cmdbus, events, SSE, KV — stayed up. Removing
the whole writer would have measured the wrong thing: the availability brief's
point is that the tier is the one writer dependency with a fallback.

```
=== arm killswitch: 22 passed, 0 failed ===
```

| property | result |
| :-- | :-- |
| the tier-service metric surface | **entirely absent** (9/9 series) — `/metrics` fell 429 → 303 lines. #260's discriminating `off` arm, reproduced inside the bundle |
| the read | every replica **alive** (`/healthz` answers) and **refused** the tier read — no silent fall-back to the pod-local store |
| the comparator | `ehdb_unavailable` from all three replicas, naming the failed hop. **Never `match`** |
| the caller | 3/3 executions completed during the outage with a complete set in the incumbent |

"Alive and refused" is asserted as two separate facts on purpose: an unreachable
pod and a fail-loud refusal look identical from the outside, and only one of them
is the safety property.

### Recovery — re-promotion on a real success, with no restart

`tierup` restored the face. The worker pods were **never rolled** (same pod IPs,
no restarts), so belief was restored by real successful operations rather than by
a process restart or a timer:

```
tier-service metric series back:            20
replica 10.244.0.111 -> records=13 source=service
replica 10.244.0.112 -> records=13 source=service
replica 10.244.0.110 -> records=13 source=service
comparator: {"outcome":"match","source":"service","ehdb":13,"auth":13,"holds":true,"div":0}
```

---

## Rollback, rehearsed

One command, symmetric with the flip, no image change:

```bash
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_EHDB_EVENTLOG=shadow
```

Post-rollback state: see the final `service` arm below. `MIRROR_SOURCE=server`
and `TIER_QUERY_SOURCE=service` were deliberately **left in place** — they are
not part of the flip, and rolling them back would undo the full-set mirror and
re-fragment the tier.

Post-rollback `service` arm, on the same cluster:

```
=== arm service: 41 passed, 0 failed ===
```

13/13 from all three replicas, one `match` verdict per pin, `holds: true`,
`divergences: 0`, and the observability moving on the right labels again
(`append/ok +13`, `read_execution/hit +7`, store `+13`, non-zero histogram sums).
The cluster is in the same measured state after the flip-and-rollback cycle as
before it.

The flip and the rollback were each executed with the exact command in
`RUNBOOK.md` §2 / §4 — `deploy.sh mode primary|shadow` is a one-line wrapper
around them, so the runbook cites commands that have been run.

---

## Findings this run produced

**1. ⛔ `primary` is inert on the serve-ready configuration.** The headline, above.
The two changes that make the tier *correct* at multiple replicas
(`MIRROR_SOURCE=server`, `TIER_QUERY_SOURCE=service`) are the two that route
around every caller of the serve policy. This is not a regression in either of
them — each is right on its own terms. It is a gap that only a **composed** gate
could surface, and it is the reason this capstone exists.

**2. The flip is signal-silent, which is worse than the stale warning #259 is
about.** `warn_primary_not_wired` is reached from `runtime_hook_env`, which
`MIRROR_SOURCE=server` short-circuits. So the fix on
`fix/259-primary-flip-signal` — three distinct conditions instead of one wrong
one — would still emit nothing here. Landing it is necessary and not sufficient.

**3. `playbook.completed` is not the last event of an execution.** The probe
emits a further `step.enter / command.issued / claimed / started / call.done /
command.completed` run after it, so an execution settles at 13, 19 or 22
depending on timing. A 6-poll / 12-second quiet window latched at 13 against one
that wrote 19 — the same class of defect the previous gate fixed by going from 2
polls to 6, one size too small. Now 10 polls at 3s, **and** every count assertion
is an equality within a single response rather than against a captured constant,
so a late arrival is reported as drift instead of failing the tier.

**4. A gate that pins the relay must un-pin it.** Section 5 leaves the server's
relay aimed at the last replica it measured. The next roll gives every pod a new
IP, and the comparator then correctly answers `ehdb_unavailable` — but the run
that read `authoritative_count` off *that* reply saw `null`, applied `// 0`, and
aborted an entire arm reporting that an execution had written no events. It had
written 13. **Fail-loud on one side, misread on the other**: the settle target
must not depend on the thing under test, and now comes from
`/api/executions/<id>`.

**5. `playbooks/261-tier-query-service/PENDING-PUSH.md` names the wrong metric.**
The counter is `noetl_worker_ehdb_query_ops_total{operation="tier_query_source.*"}`,
not `noetl_ehdb_query_ops_total`. A wiki page written from that line would
document a series that does not exist.

**6. The server's PR-4 commit is not on the branch its own staging document
names.** `playbooks/261-tier-query-service/PENDING-PUSH.md` describes a server
branch `feat/257-pr4-tier-query-service` @ `2206728`; no such branch exists —
`2206728` is the tip of `feat/258-server-authored-mirror`. Two staged documents
disagree about the shape of the stack. See `PENDING-PUSH.md` §1.

---

## What this does NOT establish

* **It is not a promotion.** No tier is `primary` outside this kind cluster.
* **The store is still pod-local RWO behind a single writer.** That is the
  accepted posture (`docs/rfc/ehdb-primary-serve-availability.md`), not something
  this gate improves. There is still no PodDisruptionBudget in namespace `noetl`.
* **Prod soak parity is not measured here.** Preconditions P5/P6 in `RUNBOOK.md`
  are prod-side and remain open.
* **The gate worker image is not DuckDB-capable** (`--features
  duckdb-integration` cannot build offline). Sound for this gate; not for one
  that exercises a DuckDB step.

## State left behind

Kind restored to released images, verified rather than assumed:

```
noetl-server-rust     ghcr.io/noetl/server:3.79.2
noetl-worker-rust     ghcr.io/noetl/worker:5.115.3-arm64   (0 replicas, KEDA paused-replicas=0)
noetl-cmdbus-writer   ghcr.io/noetl/worker:5.115.3-arm64

NOETL_EHDB_* remaining:
  server: NOETL_EHDB_WORKER_QUERY_URL=…  (the value that was there before this
          session, restored deliberately)
  worker pool: none
  writer:      none
```

⚠ The writer's PVC still holds `/data/eventbus/tier/eventlog.jsonl` with this
session's records. It is inert — no listener, `NOETL_EHDB_TIER_SERVICE_BIND` is
unset — but a future run's "before" figures will count them. Every count in this
document is a delta measured within its own run for that reason.

Prod, checked read-only and unchanged:

```
gke_shastaratech-noetl-prod_…   worker pool: NOETL_EHDB_EVENTLOG=shadow
                                no NOETL_EHDB_TIER_* on any workload
```

**No prod change of any kind. No tier promoted to `primary`. No
`NOETL_EHDB_TIER_*` on prod. Nothing pushed** — see `PENDING-PUSH.md`.
