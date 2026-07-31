# ROLLBACK — T3 events migration

Every stage is reversible by **env var only** until NATS teardown (T5), which is
out of scope here and human-gated. No stage in this playbook deletes anything.

Baseline to return to (verified on prod 2026-07-31):

| Workload | Var | Baseline value |
|---|---|---|
| `noetl-server-rust` | `NOETL_EVENT_BUS` | *(unset — defaults to `nats`)* |
| `noetl-server-rust` | `NOETL_EVENT_INGEST_PUBLISH_ONLY` | `true` |
| `noetl-worker-system-pool` (+ `-shard1`) | `NOETL_MATERIALIZER_ENABLED` | `true` |
| `noetl-worker-system-pool` (+ `-shard1`) | `NOETL_RESULT_MATERIALIZER_ENABLED` | `true` |
| `noetl-worker-system-pool` (+ `-shard1`) | `NOETL_STATE_BUILDER` | `offserver` |
| `noetl-worker-system-pool` (+ `-shard1`) | `NOETL_*_SOURCE` | *(unset — defaults to `nats`)* |
| `gateway` (ns `gateway`) | `NATS_UPDATES_SUBJECT_PREFIX` | `noetl.events.` |
| `gateway` (ns `gateway`) | `EVENT_BUS_SSE_URL` | *(unset)* |

Images at baseline:

| Workload | Image |
|---|---|
| `noetl-server-rust` | `noetl-server-rust` v3.58.3 |
| `noetl-worker-rust`, system pool, `noetl-cmdbus-writer-0` | `noetl-worker-rust` v5.81.3 |
| `gateway` | as deployed 4d13h (unchanged by T3 until step 2d) |

All commands assume:

```bash
export CLOUDSDK_CORE_ACCOUNT=shastaratech@gmail.com
export KCTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
```

An identity mismatch on `CLOUDSDK_CORE_ACCOUNT` presents exactly like a policy
denial — if a command 403s, check the account before believing the error.

---

## Stage 1 — shadow (dual-publish) → back to NATS-only

Cheapest rollback in the whole playbook: the EHDB publish is additive and
nothing consumes it yet.

```bash
kubectl --context $KCTX -n noetl set env deploy/noetl-server-rust NOETL_EVENT_BUS-
kubectl --context $KCTX -n noetl rollout status deploy/noetl-server-rust
```

Verify: `noetl_events` still growing under driven load, and the server's EHDB
event-publish counter on `:9102` flat.

**Risk if skipped:** none — shadow never removes the NATS publish.

---

## Stage 2a/2b/2c — a materializer back to the NATS source

Per consumer. Substitute the matching var:

| Consumer | Var |
|---|---|
| state materializer | `NOETL_STATE_MATERIALIZER_SOURCE` |
| result materializer | `NOETL_RESULT_MATERIALIZER_SOURCE` |
| event materializer (**durable log**) | `NOETL_MATERIALIZER_SOURCE` |

```bash
for d in noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  kubectl --context $KCTX -n noetl set env deploy/$d NOETL_MATERIALIZER_SOURCE-
done
kubectl --context $KCTX -n noetl rollout status deploy/noetl-worker-system-pool
kubectl --context $KCTX -n noetl rollout status deploy/noetl-worker-system-pool-shard1
```

**Both** deployments must be flipped together — they are two pods of one
queue-group. Flipping one leaves a split-brain group where half the records
drain from NATS and half from EHDB.

The NATS durable consumers are never deleted during T3, so their cursors are
still valid. On rollback the consumer resumes from its NATS cursor and drains
whatever accumulated (`max_age = 1d` bounds the backlog; a rollback inside 24h
loses nothing).

**Rollback deadline: 24h.** `noetl_events` has `max_age = 1d`. Beyond that the
NATS cursor's backlog has aged out and rolling back leaves a gap in whatever
that consumer writes — for `noetl_materializer` that gap is in the durable event
log. If a rollback is needed past 24h, backfill from the EHDB log rather than
from NATS.

---

## Stage 2d — gateway SSE back to NATS

```bash
kubectl --context $KCTX -n gateway set env deploy/gateway EVENT_BUS_SSE_URL-
kubectl --context $KCTX -n gateway rollout status deploy/gateway
```

The gateway's NATS path is a core-NATS subscribe with no cursor, so it resumes
live immediately and loses only what was published while it was reconnecting.
No backfill concept applies.

Verify by driving a playbook and watching an SSE client receive lifecycle
frames — not by reading logs, which fail **soft** here (`main.rs:131` logs a
warning and continues). A silent gateway is the failure mode, so absence of
errors proves nothing.

---

## Stage 3 — EHDB-only → back to shadow

```bash
kubectl --context $KCTX -n noetl set env deploy/noetl-server-rust NOETL_EVENT_BUS=shadow
kubectl --context $KCTX -n noetl rollout status deploy/noetl-server-rust
```

This restores the NATS publish. Consumers stay wherever they are; roll them back
individually per stage 2 if needed.

---

## Full revert to the 2026-07-31 baseline

```bash
kubectl --context $KCTX -n noetl set env deploy/noetl-server-rust NOETL_EVENT_BUS-
for d in noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  kubectl --context $KCTX -n noetl set env deploy/$d \
    NOETL_MATERIALIZER_SOURCE- NOETL_RESULT_MATERIALIZER_SOURCE- NOETL_STATE_MATERIALIZER_SOURCE- \
    NOETL_EVENT_BUS_CLAIM_ADDR-
done
kubectl --context $KCTX -n gateway set env deploy/gateway EVENT_BUS_SSE_URL-
```

Then confirm the four consumers are healthy on NATS:

```bash
NB=pod/nats-box-5fc48fbf49-dhjh7
kubectl --context $KCTX -n nats exec $NB -- \
  nats --server nats://noetl:noetl@nats.nats.svc.cluster.local:4222 \
  consumer ls noetl_events
```

Expect `noetl_materializer`, `noetl_result_materializer`,
`noetl_state_materializer` with `Unprocessed: 0` under driven load.

If images also need reverting, roll back the deployment rather than re-tagging:

```bash
kubectl --context $KCTX -n noetl rollout undo deploy/noetl-server-rust
```

---

## What rollback does NOT cover

- **Events already written only to EHDB.** During stage 3 the NATS publish is
  off; events in that window exist only in the EHDB log. Rolling back to
  `shadow` resumes dual-publish but does **not** backfill NATS. That is
  acceptable — NATS is not a system of record; `noetl.event` is, and the
  materializer keeps writing it either way. Stated here so nobody expects a
  backfill that was never designed.
- **NATS teardown.** Out of scope. Nothing in T3 deletes the stream, the
  StatefulSet, the PVC, or `nats-supercluster`.
