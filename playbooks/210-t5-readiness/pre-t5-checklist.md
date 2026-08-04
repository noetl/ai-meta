> **SUPERSEDED 2026-08-04 — T5 IS DONE.** Everything below is the audit as it
> stood on 2026-07-31 and is kept for the record. All four blockers were
> subsequently cleared (T3 via noetl/ai-meta#212, T3c via #214, T3d via #215)
> and NATS was deleted. Re-verified against prod on 2026-08-04: no `nats`
> namespace, nothing named nats cluster-wide, no NATS PVC, and no `NATS_*`
> variable on any workload in ns `noetl` or ns `gateway`. Do not read the
> blocker list below as current state.

# Pre-T5 checklist — what still references NATS on shastaratech prod

Audited 2026-07-31 on
`gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`, after the
T5-readiness deploy. T5 = deleting the NATS StatefulSet + PVC.

**T5 is NOT safe to run on this inventory yet.** The command bus is clean, but
NATS still carries a second, live workload — the `noetl_events` stream — that
was never cut over. Details in "Blockers" below.

## Evidence the command bus no longer needs NATS

```
$ nats stream ls
NOETL_COMMANDS_RUST   2,283 msgs   last message 2d23h ago
noetl_events          2,259 msgs   last message 3m ago     <-- still live
```

`NOETL_COMMANDS_RUST` has been silent since the T4 flip. That is the stream T5
was scoped around, and it is genuinely idle.

## Blockers — must be resolved before T5

### B1. The `noetl_events` stream is actively in use (this is T3, not done)

`noetl_events` has six consumers, four of them delivering within the last
3 minutes:

| Consumer | Last delivery | What it is |
|---|---|---|
| `noetl_materializer` | 3m | worker-side event materializer |
| `noetl_result_materializer` | 3m | result-tier materializer |
| `noetl_state_materializer` | 3m | state materializer |
| `91ImhSiK`, `ZsoCGuy1` | 3m | ephemeral — gateway SSE subscriptions |
| `noetl_projector` | never (2 259 unprocessed) | orphaned; safe to delete |

Deleting NATS stops all of these. T3 in the [#194](https://github.com/noetl/ai-meta/issues/194)
plan ("gateway/SPA feed cutover off `noetl.events.>`") is still unchecked, and
this is what it refers to.

### B2. The gateway degrades — quietly, and in ways users feel

`deployment/gateway` in ns `gateway` carries
`NATS_URL=nats://noetl:noetl@nats.nats.svc.cluster.local:4222` and
`NATS_UPDATES_SUBJECT_PREFIX=noetl.events.`. All three of its NATS uses
fail **soft** (`main.rs:99`, `:120`, `:131` — each logs a warning and
continues), so the gateway will not crash without NATS. What it loses:

- `Session cache disabled … all validations will query Postgres via NoETL API`
  — degraded, tolerable (the #168 sync auth fast-path covers the hot path).
- `Request store disabled … **async callbacks will not work**` — functional loss.
- `Execution lifecycle SSE forwarding disabled` — **the SPA stops receiving live
  updates**. This is the user-visible one.

Both KV buckets (`sessions`, `requests`) are currently empty with
`Last Update: never`, so nothing is depending on their *contents* — but the code
paths that would populate them are live.

## Non-blockers — teardown steps that ride along with T5

### N1. The `nats-jetstream` KEDA trigger becomes a no-op

`scaledobject/noetl-worker-rust` carries two triggers; KEDA takes MAX across
them. Trigger (2) reads consumer `noetl_worker_rust_shared` on
`NOETL_COMMANDS_RUST`, whose backlog is permanently 0 since the T4 flip. Removing
it is a T5 *teardown* step, not a prerequisite — the EHDB `metrics-api` trigger
already carries the pool. Delete trigger (2) from
`ops/ci/manifests/keda/scaledobject-worker-rust-prod.yaml` as part of T5.

### N2. NATS env vars on the noetl workloads

Remove in the same change set as the StatefulSet:

| Workload | Vars |
|---|---|
| `noetl-server-rust` | `NOETL_NATS_URL` |
| `noetl-worker-rust` | `NATS_URL`, `NATS_STREAM`, `NATS_CONSUMER`, `NATS_FILTER_SUBJECT` |
| `noetl-worker-system-pool` (+ `-shard1`) | same four, plus `WORKER_NATS_LAG_POLL_INTERVAL` |
| `noetl-cmdbus-writer-0` / `-1` | `NATS_STREAM`, `NATS_CONSUMER`, `NATS_FILTER_SUBJECT` (`NATS_URL` already empty) |
| `gateway` (ns `gateway`) | `NATS_URL`, `NATS_UPDATES_SUBJECT_PREFIX`, `NATS_REQUEST_TTL_SECS` — **only after B1/B2** |

The server fails soft too (`connect_nats` → `"Failed to connect to NATS,
continuing without it"`), so a stale var is not a crash risk; it is hygiene.

### N3. The plaintext `noetl:noetl` credential ([#188](https://github.com/noetl/ai-meta/issues/188))

Every URL above embeds `noetl:noetl` inline in Deployment env. #188 tracks moving
it to a Secret/keychain and rotating. **T5 retires it for free** for every
workload whose NATS env goes away — which is the whole inventory once B1/B2 are
resolved. If T5 slips, #188 should be done on its own.

### N4. Namespaces

- `nats` — the StatefulSet (1 replica), `nats-box`, two Services, and PVC
  `nats-js-nats-0` (5 Gi). This is what T5 deletes.
- `nats-supercluster` — `nats-cluster-a` and `nats-cluster-b`, 3 pods each, 6
  pods total. **No workload in the cluster references either service** (checked
  every Deployment/StatefulSet env cluster-wide for `nats-cluster` /
  `supercluster` — zero hits). Looks like a leftover experiment. Worth deleting
  regardless of T5, but confirm with the human first — 6 running pods of
  unexplained provenance deserve a question, not an assumption.

## Suggested T5 order

1. Land T3: move the `noetl.events.>` fan-out (materializers + gateway SSE) off
   NATS. **This is the real remaining work** — it is a program phase, not a
   checklist item.
2. Re-run this audit; `noetl_events` should go quiet the way
   `NOETL_COMMANDS_RUST` has.
3. Remove the `nats-jetstream` trigger (N1) and the env vars (N2).
4. Delete the `nats` namespace's StatefulSet + PVC.
5. Close #188 as retired-by-removal.
6. Decide separately on `nats-supercluster` (N4).
