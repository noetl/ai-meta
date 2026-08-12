# ai-meta#257 — consolidated serve-readiness gate: results

Kind cluster `kind-noetl`, **three worker replicas**, on built images. The
go/no-go evidence for promoting the EHDB event-log tier.

**Two runs, both 2026-08-12.** Run 1 found the P0; run 2 closes it. Run 1's
sections are kept below verbatim under *Run 1* — they are the evidence the
defect existed, and deleting them would leave the fix unmotivated.

---

## Verdict (run 2, worker `8d46b33`)

> **The serve-readiness bundle is GREEN and the flip now reaches the serve
> path.** P0 — the one hard blocker — is closed. The remaining preconditions are
> unchanged: P5 (prod soak), P6 (monitoring applied, zero notification
> channels), P7 (availability posture in writing), P8's `#259` half, and P9
> (explicit per-tier go) are all still open, and three of those are prod-side.
>
> On `MIRROR_SOURCE=server` + `TIER_QUERY_SOURCE=service` at three replicas,
> `NOETL_EHDB_EVENTLOG=primary` produces `served_primary` **+13** per execution,
> `serve_state=served_primary` on the tier endpoint, and one log line per
> transition — while the tier still holds the full authoritative set (13/13 from
> all three replicas, one `match` verdict per pin) and the incumbent still
> receives a complete set (3/3).
>
> A mutation reinstating the bypass fails **exactly** the two serve assertions
> and nothing else: 47 passed, 2 failed. Restoring returns 49/0.

### Verdict (run 1) — kept, because it is why run 2 exists

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

# Run 2 — the P0 fix, measured

## What changed

Worker `8d46b33` on `feat/257-serve-readiness`, on top of `a87dd14`. Four files:
`src/ehdb/eventlog.rs`, `src/ehdb/metrics.rs`, `src/ehdb/tier_store.rs`,
`src/metrics_server.rs`.

**The third call site.** `primary_serve::decide` had two, and the serve-ready
configuration routed around both — `MIRROR_SOURCE=server` disarms the worker's
mirror hook before the tier mode is consulted, and `TIER_QUERY_SOURCE=service`
takes `Resolution::Service(client)`, which never enters `mirror_event`. The fix
puts the decision at the append chokepoint that configuration *does* reach: the
`Resolution::Service` branch of `ehdb_tier_append_handler`, via
`eventlog::serve_service_append`.

It is **not** a second policy. It calls the same `decide` with the same three
conditions and maps the verdict onto the same outcome vocabulary `mirror_event`
uses. A property test walks all eight input combinations and asserts this site's
verdict equals `decide`'s — so the two sites cannot drift apart about what
`primary` means.

The three conditions, all measured:

| condition | how |
| :-- | :-- |
| primary mode | `NOETL_EHDB_EVENTLOG=primary` + the compile-time `PRIMARY_SERVE_ACTIVATED` |
| durable service reachable | `reachability::is_reachable()` — set only by a real successful operation, cleared by any transport failure. The append that produced the reply **is** that operation, so this is a post-append fact, not a cached poll (the arm-D discipline) |
| parity held | the remote store's own reply. `tier_store::append` now returns `log_record_count`, so the caller can check `log_record_count == global_sequence` — the same gapless invariant `mirror_event` checks locally — plus batch-local ordering |

Parity here is **self**-consistency, not cross-store parity: it catches a store
that has forgotten or rewound, which a promoted tier would otherwise answer from
confidently. Parity against `noetl.event` stays the server comparator's job,
because per `data-access-boundary.md` the worker may not read `noetl.*`. Ordering
is checked batch-locally on purpose — the store has N appenders and
process-global bookkeeping would report a divergence whenever two batches
interleaved.

**Two things that made the defect invisible, closed:**

* **The serve series is pinned.** `served_primary` was not 0, it was *absent*,
  and an absent family is the same bytes as a build with no serve path. It is now
  created at 0 at the bind site of the route that carries server-authored
  appends. Gated on EHDB enabled + tier not `off`, so a disabled build's
  `/metrics` stays byte-identical — and **both** `shadow` and `primary` pin, so
  the flip changes values, never which series exist. Measured, on a shadow pod
  before any traffic:

  ```
  noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="mirrored"} 0
  noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="parity_mismatch"} 0
  noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="primary_divergence"} 0
  noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="primary_unavailable"} 0
  noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="rejected"} 0
  noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="served_primary"} 0
  noetl_ehdb_eventlog_ops_total{operation="mirror",outcome="unavailable"} 0
  ```

* **The serve state is at the endpoint and in the log.** `serve_state` on the
  tier route's replies (event-log tier only — a bare `serve_state` on a `kv` body
  would describe the wrong thing), and one log line per transition in **both**
  directions. Transition-only because an append happens 13 times per execution
  and a line on each is a line nobody reads, which is operationally the same as
  the no-line state P0 was found in.

## Images

| tag | image id | source |
| :-- | :-- | :-- |
| `localhost/noetl-worker:capp0` | `e6a592eafc6f` | composed tree @ `8d46b33` |
| `localhost/noetl-worker:capp0mut` | `d1ca3aa83326` | same + `mutation-p0.patch` |
| `localhost/noetl-server:pr4real` | `f2fa90c38021` | server `2206728` (unchanged from run 1) |

Distinct ids confirm the mutation reached the binary. `deploy.sh load` asserted
each tag present in the kind node **by name** before arming.

## Arm `service` — the bundle, with the two new controls

```
=== arm service: 45 passed, 0 failed ===
```

19/19 from all three replicas (`10.244.0.138/139/140`), one `match` verdict per
relay pin, `holds: true`, `unmirrored_by_design 0`, `divergences 0`, observability
moving (`append/ok +19`, `read_execution/hit +7`, store `+19`, histogram sums
`0.083138` / `0.022832`, `+Inf == count`).

Four assertions are new. Two matter on their own:

* **the pin** — `the serve-decision series is pinned on every replica (0, not
  absent)`. This is the assertion whose absence let run 1's zero look like a
  reading rather than a hole.
* **the negative control** — `no replica served as primary while the tier is
  shadow`, paired with `the serve site ran and recorded on the shadow label`.
  Without the pair, `served_primary > 0` under `primary` would be satisfied by a
  recorder that fired unconditionally. Same code, same traffic, only the flip
  differs.

## Arm `primary` — the flip, and it serves

```
=== arm primary: 49 passed, 0 failed ===
```

```
replica 10.244.0.145  served_primary=13 primary_unavailable=0 serve_state=served_primary  (baseline 0)
replica 10.244.0.147  served_primary=0  primary_unavailable=0 serve_state=unknown         (baseline 0)
replica 10.244.0.146  served_primary=0  primary_unavailable=0 serve_state=unknown         (baseline 0)
TOTAL: served_primary=13 (delta +13)   endpoint served_primary: 1/3
```

Three independent readings, because run 1 had all three silent at once:

| reading | result |
| :-- | :-- |
| the counter **moved**, as a delta against this run's own baseline | `+13` — and the baseline was `0`, not `__ABSENT__`, so the pin held |
| the **endpoint** | `serve_state=served_primary` on 1/3 replicas |
| the **log**, once per transition | `NOETL_EHDB_EVENTLOG=primary IS SERVING: the event-log tier answered authoritatively through the writer-fronted tier service (mirror_source=server, tier_query_source=service) serve_state="served_primary" outcome="served_primary"` |

**Why 1 of 3 and not 3 of 3, and why the gate asserts ≥1.** The server's mirror
hop resolves the pool's ClusterIP Service, so which replicas receive appends is a
load-balancing outcome, not something this gate controls. A replica that received
none has decided nothing and reports `unknown` — which is a different statement
from `not_primary` and must not be conflated with it. Requiring 3/3 would be
asserting a property of kube-proxy. Over the whole run two of the three pods
logged the serve line.

Everything the `service` arm asserts still held under `primary`: 13/13 from all
three replicas, one `match` verdict, `holds: true`, observability moving. And the
incumbent kept the complete set through the primary window:

| execution | events | `playbook.completed` | issued / completed |
| :-- | --: | --: | :-- |
| 345861381431496704 | 13 | 1 | 2 / 2 |
| 345861509785587712 | 13 | 1 | 2 / 2 |
| 345861624759848960 | 13 | 1 | 2 / 2 |

## Mutation check — the bypass, reinstated

`mutation-p0.patch` removes the third call site and nothing else. The appends
still land, every replica still agrees, the comparator still says `match`, the
observability still moves.

```
=== arm primary: 47 passed, 2 failed ===       (worker pool on capp0mut, writer on capp0)
```

```
  FAIL  served_primary did not move (delta 0) across any replica while 13 events flowed —
        'primary' took no different branch on this configuration
  FAIL  no replica reports serve_state=served_primary at the endpoint;
        a metric-only signal is how the P0 stayed invisible
```

**Only the pool image was swapped** (`deploy.sh poolimg`), because the serve
decision runs in the pool's append handler — swapping the writer too would move a
second variable for no reason.

**The 47 that still passed are the point.** 13/13 full-set match from all three
replicas, one verdict, `holds: true`, `divergences: 0`, every observability
delta, and the incumbent 3/3. A bundle without the serve assertions would have
reported 47 green checks about a flip that changed nothing — which is precisely
run 1's state.

One improvement over run 1 worth naming: under the mutation `served_primary`
reads **`0`**, not absent, because `capp0mut` still carries the pin. The gate now
fails on "did not move" rather than on "series absent" — a sharper signal about a
narrower fault.

**Restoring `capp0` returned the same cluster to 49 passed / 0 failed** (exit 0),
so the two failures are attributable to the mutation and not to drift.

## Arm `killswitch` — demote, visibly

```
=== arm killswitch: 23 passed, 0 failed ===
```

| property | result |
| :-- | :-- |
| the serve counter | `served_primary` **+0** through the outage — it stopped, and the stop is not the only signal |
| the demote, on the metric | `unavailable` moved **+23** and **+41** on the two replicas receiving appends. A serve signal that merely stops incrementing is indistinguishable from no traffic; this is the difference |
| the demote, in the log | `NOETL_EHDB_EVENTLOG=primary is NOT serving — the incumbent answers (demoted: no_durable_service)`, `detail="tier-service append failed: connect: Connection refused (os error 111)"` |
| the tier-service metric surface | entirely absent (#260's discriminating `off` arm, reproduced) |
| the read | every replica **alive** (`/healthz` answers) and **refused** — no silent fall-back |
| the comparator | `ehdb_unavailable` from all three replicas. **Never `match`** |
| the caller | 3/3 executions completed during the outage with a complete set in the incumbent |

### Recovery — re-promotion on a real success, no restart

`tierup`, then one execution:

```
10.244.0.146  served_primary 39 -> 41   serve_state=served_primary
10.244.0.145  served_primary 13 (unchanged)  serve_state=no_durable_service
10.244.0.147  served_primary 0  (unchanged)  serve_state=unknown

restartCount: 0  0  0
```

Zero restarts, so belief was restored by a real successful operation rather than
by a bounce or a timer. The replica that received no append **stayed demoted**,
and that is correct: belief is per-process and only its own success restores it.

## Rollback

```bash
kubectl -n noetl set env deploy/noetl-worker-rust NOETL_EHDB_EVENTLOG=shadow
```

Post-rollback `service` arm on the same cluster: **45 passed, 0 failed** — 19/19
from all three replicas, one `match`, `divergences: 0`, observability moving
(`append/ok +25`, store `+25`, sums `0.180728` / `0.049828`). The fresh pods pin
`served_primary` at 0 while `mirrored` moves, which is the shadow reading the
negative control asserts. `MIRROR_SOURCE=server` and `TIER_QUERY_SOURCE=service`
were deliberately left in place — they are not part of the flip.

## Unit gate

660 tests pass (`cargo test --lib`), including eleven new ones for the serve
site: the eight-combination equality against `decide`, primary-serves-when-all-
three-hold, never-serves-without-a-reachable-service, demote-on-divergence
(count and ordering), shadow-mirrors-and-never-claims-to-serve, off-and-disabled
record nothing, a-record-that-did-not-land-demotes-visibly,
a-rejected-record-does-not-demote-the-whole-tier, ordering-only parity when the
writer omits the count, the transition signal in both directions, and a guard
that the **pinned label set covers every outcome this site records** — the drift
check from `representation-drift.md`, since a pinned set missing one value
reintroduces the absent-series bug on that value alone.

The decision function is split so the two process globals (the tier-client env
and the reachability latch) are read in exactly one place and the tests take the
verdict as a parameter. `cargo test` does not serialise tests, so a test that
drove either global would race every other test in the binary.

## What run 2 does NOT establish

* **It is not a promotion.** No tier is `primary` outside this kind cluster.
* **P1–P9 minus P0 are untouched.** P5 (prod soak), P6 (monitoring applied; prod
  still has zero notification channels), P7 (posture in writing), P9 (per-tier
  go) are open, and P8's `#259` half is still unlanded.
* **The composed mutation (`mutation.patch`) was not re-run.** It targets the
  `service` arm; `mutation-p0.patch` targets `primary`. Run 1's 25/15 result for
  the former stands, and nothing in this fix touches the read path or the
  tier-service request signal it breaks.
* **Single writer, RWO store, no PodDisruptionBudget in namespace `noetl`.**
  Unchanged accepted posture.
* **The gate worker image is not DuckDB-capable** (`--features
  duckdb-integration` cannot build offline).

## State left behind (verified, not assumed)

```
noetl-server-rust     ghcr.io/noetl/server:3.79.2
noetl-worker-rust     ghcr.io/noetl/worker:5.115.3-arm64   (0 replicas, KEDA paused-replicas=0)
noetl-cmdbus-writer   ghcr.io/noetl/worker:5.115.3-arm64

NOETL_EHDB_* remaining:
  worker pool: none
  writer:      none
  server:      NOETL_EHDB_WORKER_QUERY_URL=…   (the value that was there before)
```

Prod, read-only and unchanged: `NOETL_EHDB_EVENTLOG=shadow`, no
`NOETL_EHDB_TIER_*` and no `NOETL_EHDB_EVENTLOG_MIRROR_SOURCE` on any workload.

⚠ The writer's PVC still holds `/data/eventbus/tier/eventlog.jsonl` with both
runs' records (sequence ~180 at the start of run 2). Inert — no listener — but a
future run's "before" figures will count them, which is why every number here is
a delta measured inside its own run.

---

# Run 1 — the bundle that found P0

Everything below is run 1, unchanged.

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

**1. ⛔ `primary` is inert on the serve-ready configuration.** — **FIXED in run 2
by worker `8d46b33`.** The original text follows.
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
document a series that does not exist. — **FIXED in run 2**: the line is
corrected in place, with the correction marked.

**6. The server's PR-4 commit is not on the branch its own staging document
names.** `playbooks/261-tier-query-service/PENDING-PUSH.md` describes a server
branch `feat/257-pr4-tier-query-service` @ `2206728`; no such branch exists —
`2206728` is the tip of `feat/258-server-authored-mirror`. Two staged documents
disagree about the shape of the stack. — **FIXED in run 2**, ref-only: the branch
`feat/257-pr4-tier-query-service` now exists at `2206728` and
`feat/258-server-authored-mirror` was moved back to `b97e3bf`, its own commit. No
commit was lost; both are reachable, and the two staged documents now describe
the same stack. See `PENDING-PUSH.md` §1.

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
