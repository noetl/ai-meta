# #260 — making the tier service's server half observable

**Status:** built + kind-validated, default-off, nothing on prod.
**Tracks:** [ai-meta#260](https://github.com/noetl/ai-meta/issues/260),
[ai-meta#257](https://github.com/noetl/ai-meta/issues/257) PR 6.

---

## 1. The finding this closes

`repos/worker/src/ehdb/tier_service.rs` recorded **zero metrics**. The whole
file's observability was four `tracing` lines, three of them on failure paths.

That file is the process that `primary` promotes to authoritative. The client
half was already instrumented — `record_tier_client` routes into
`noetl_ehdb_dataplane_ops_total{operation="tier_client.*"}` — so when a tier
flip went wrong, the only prod-side signal was a demotion counter recorded **by
the caller**, which cannot distinguish "the service is unhealthy" from "the
network is". No served-request count, no hit/miss, no latency, no error
taxonomy, no store size, on the component being promoted.

This is the [`representation-drift`](../../agents/rules/representation-drift.md)
family one level up: not a description that stopped being true, but a component
with no way to be wrong out loud.

## 2. The metric design

Everything lands on the **existing** `noetl_ehdb_*` families, on the worker's
existing `/metrics` (`:9090`). No new registry surface, and — per #260's last
bullet — **no PodMonitoring change**: the writer's Service already publishes
9090, so [ops#255](https://github.com/noetl/ops/pull/255) needs only to be
applied, not amended.

| metric | type | labels | answers |
| :-- | :-- | :-- | :-- |
| `noetl_ehdb_dataplane_ops_total` | counter | `operation="tier_service.<op>"`, `outcome` | what was served, and how it went |
| `noetl_ehdb_tier_service_duration_seconds` | histogram | `operation` | how long the service took |
| `noetl_ehdb_tier_service_store_appends_total` | counter | — | how much this process has written |
| `noetl_ehdb_tier_service_store_sequence` | gauge | — | how many records the store holds |
| `noetl_ehdb_tier_service_store_bytes` | gauge | — | how big the store is on disk |

### The closed label set — 20 series, enumerated not cross-produced

```
health          ok
append          ok | invalid | unavailable | error
read_execution  hit | miss | invalid | unavailable | error
scan            hit | miss | unavailable | error
unsupported     unsupported
conn            accepted | closed | protocol_error | write_error | accept_error
```

A cross-product would invent series that cannot happen (`health` can never be
`miss`), and a series pinned at 0 **forever** is a worse lie than an absent one:
it asserts something is being watched when nothing can move it. `scan` has no
`invalid` because it clamps its limit rather than rejecting it.

Three decisions worth naming:

* **`hit` / `miss` on reads.** On a promoted tier the distinction that matters is
  not "did the read succeed" but "did it return anything" — an all-`miss` read
  stream means the store is serving, and empty. Classified from the body the
  store just produced, in the same pass that encodes it, so there is only one
  implementation of the decision.
* **`degraded` is not `!ok`.** A malformed request is `ok=false, degraded=false`
  — the caller got a correct refusal and the service is fine. `unavailable` and
  `error` are `degraded`, because a tier promoted here could not answer. An alert
  on `degraded` must not fire because someone sent a bad frame.
* **The unknown op name is not a label.** `Unsupported(op)` carries a
  caller-controlled string; it stays in the reply and out of `operation`, which
  would otherwise be unbounded cardinality.

### The counter and the histogram cannot drift apart

One function, `record_tier_service`, increments both. Two functions would let a
call site move one and not the other — a defect that renders as a perfectly
plausible dashboard.

### The pin, and where it is allowed to be conditional

Every series is created at 0 **when the listener binds**, from one call site in
`event_bus.rs`. Below that bind the pin is unconditional: not gated on a store
being configured, on tier mode, or on any `NOETL_EHDB_*`. That is the
[server#315](https://github.com/noetl/server/pull/315) mistake — pinning
publish-skip reasons inside `if publishes_ehdb()`, leaving them absent on exactly
the configuration whose skip reason someone would be reading.

The inverse is deliberate: **with no listener, nothing is pinned**, and
`/metrics` stays byte-identical to a build without the module. That is correct
rather than a loophole — absence then means "this process has no tier service",
which is true and useful, and `noetl_worker_build_info{version}` already answers
"is this binary too old to have the metric". The gate's `off` arm asserts it.

The store's size and sequence are **sampled at pin time**, so a writer restarting
in front of a populated store reports what it actually holds before serving a
single request. Without that, a restart reads as an empty store.

## 3. Running the gate

```bash
cd repos/worker
cargo vendor vendor > /tmp/vendor-config.txt && mkdir -p .cargo \
  && cp /tmp/vendor-config.txt .cargo/config.toml
#  ⚠ see "traps" below before building
podman build --network none -f Dockerfile.gate -t localhost/noetl-worker:260metrics .

P=../../playbooks/260-tier-service-metrics
$P/deploy.sh load localhost/noetl-worker:260metrics
$P/deploy.sh arm up   && $P/deploy.sh forward && $P/gate.sh up
$P/deploy.sh arm off  && $P/deploy.sh forward && $P/gate.sh off
$P/deploy.sh restore
```

The gate drives the **real** length-framed TCP protocol via `tierctl.py` — not a
recorder call. A test that invoked `record_tier_service` directly would pass
against the un-instrumented module this replaces, which is the entire point.

### The three arms

| arm | env | must |
| :-- | :-- | :-- |
| `up` | `TIER_SERVICE_BIND` set, store set | every series exists at 0 before traffic; the right ones move after |
| `off` | `TIER_SERVICE_BIND` **unset**, store still set | every series **absent** |
| `mutated` | `up`, on an image built with `mutation.patch` | **FAIL** |

`off` is the discriminating arm. Without it the pinned zeros prove nothing: a
renderer that emitted those lines unconditionally would produce the same `up`
result. It keeps the store configured so the absence cannot be explained by
"there was nothing to serve from".

## 4. Traps hit while building this

* **`.dockerignore`'s `**/target` also matches vendored *source*.**
  `vendor/cc/src/target/generated.rs` is Rust source in a directory named
  `target`; the ignore rule dropped it and `cargo chef` died with `failed to
  calculate checksum`. Fixed with `!vendor/**/target` — gate-only, since the
  release build does not vendor. This is the unanchored-ignore trap in a new
  costume: the previous one was a nested build dir being *included*, this is a
  source dir being *excluded*.
* **`COPY . .` reads the working tree whenever it runs, not when the build
  started.** A build launched in the background captured the tree during a window
  when the mutation was briefly applied, making the image's provenance
  ambiguous. Both gate images here are built from a **committed** tree.
* **zsh does not word-split unquoted variables.** `K="kubectl -n noetl"; $K get
  pods` fails with `command not found: kubectl -n noetl`. `deploy.sh` uses a
  shell function.
* **`cargo test` does not serialise tests within a binary.** Instrumenting the
  serve path made `tier_service`'s tests write the accumulator that
  `metrics`'s tests assert is empty. The lock moved to module scope so both take
  the same one; two locks would serialise nothing.

## 5. What this deliberately does NOT do

* No tier is flipped to `primary`.
* Nothing is set on prod. No `NOETL_EHDB_TIER_SERVICE_*` anywhere but kind.
* ops#255 is **not** applied — it remains the user's call, and #260's own note
  is that it needs no amendment now that the metrics render on `:9090`.
* The metrics are always-on **once the service runs**; they gate no behaviour, so
  there is no flag to default off.
