# The complete path to NATS teardown — what remains after T3

T3 (the `noetl.events.>` fan-out) is the largest remaining NATS surface, but it
is **not the only one**. Three further surfaces each independently block T5.
This file inventories them with a migration + parity plan apiece, so the path to
teardown is written down rather than rediscovered.

Surveyed against `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`
on 2026-07-31, after the T3 shadow-parity proof
([`parity-result.md`](parity-result.md)).

| Workstream | Surface | Blocking T5? | Apparent effort |
| :-- | :-- | :-- | :-- |
| **T3** | `noetl.events.>` fan-out (4 consumers) | yes — in progress | large; publish half proven |
| **T3b** | `noetl.callbacks.>` request/reply | yes | **likely small — see below** |
| **T3c** | NATS KV bucket `requests` | yes | small |
| **T3d** | NATS KV bucket `sessions` | yes | small |
| T5 | delete StatefulSet + PVC + env + `nats-supercluster` | — | mechanical, human-gated |

---

## T3b — `noetl.callbacks.>` (gateway request/reply)

### What it is

`gateway/src/callbacks.rs` holds a `CallbackManager`. Three auth flows
(`auth/mod.rs:243`, `:501`, `:758`) call `register()`, which mints a
`request_id` + the NATS subject `noetl.callbacks.<request_id>`, and passes that
subject into the playbook as the `callback_subject` variable. A core-NATS
listener (`start_nats_listener`) subscribes `noetl.callbacks.>` and resolves the
waiting future when a reply arrives.

### The evidence says this is very likely already dead

Four independent signals, none conclusive alone:

1. **No publisher exists.** Nothing in `repos/` publishes to `noetl.callbacks.*`
   — not the server, not the worker, not the tools registry, and no playbook.
   The only other reference to `callback_subject` is an inline-execution
   **guard** in `noetl/core/workflow/playbook/inline_execution.py:120` that
   *blocks* inlining when the key is present.
2. **A superseding HTTP path exists.** `main.rs:238` registers
   `/api/internal/callback` — "Internal callback endpoint for workers to deliver
   results via HTTP". That is the live delivery mechanism.
3. **The prod auth flows bypass callbacks entirely.** The gateway runs
   `NOETL_AUTH_SYNC=true` ([#168](https://github.com/noetl/ai-meta/issues/168)),
   which routes session-validate and login through the synchronous server
   fast-path — no playbook dispatch, so no callback round-trip.
4. **No deliveries observed.** Zero `Received NATS callback` lines in the
   gateway's last 2000 log lines.

### Migration plan

Because the likely answer is "delete, don't migrate", the plan is **an
observation window first** — do not port a subject nothing uses.

1. **Prove it dead (1 week).** Add a counter on the NATS callback listener's
   delivery path (`callbacks.rs:134`) and scrape it. A week at zero across a
   period including real logins is the gate. *A log grep is not this gate* — the
   listener could be delivering while the log level hides it.
2. **If zero:** delete `callbacks.rs`'s NATS half, the listener, and
   `NATS_CALLBACK_SUBJECT_PREFIX`. Keep `CallbackManager`'s in-process
   registry — the HTTP endpoint uses it. Ship behind no flag; deleting a path
   with a proven-zero counter needs no rollback flag, only a revert.
3. **If non-zero:** it is a real request/reply surface and needs a transport.
   Do **not** put it on the events feed — request/reply to one waiter is not
   fan-out. Use the existing `/api/internal/callback` HTTP path instead:
   change `register()` to hand the playbook a **callback URL** rather than a
   NATS subject. That removes the surface rather than re-implementing it.

### Parity gate

- Counter at zero for ≥7 days spanning ≥1 real interactive login.
- After removal: drive a real login + a real async playbook; both complete.

---

## T3c — NATS KV bucket `requests` (gateway request store)

### What it is

`gateway/src/request_store.rs` — a JetStream KV bucket (`requests`,
`NATS_REQUEST_TTL_SECS=300`) mapping `request_id` → pending playbook request, so
a lifecycle event can be routed back to the right SSE client. The T3 gateway
listener reads it on every forwarded event
(`request_store.get_by_execution(...)`).

### Current state on prod

Bucket exists, **0 values, `Last Update: never`** since 2026-07-26. The audit
recorded this as "empty but the code paths that populate it are live".

**Correction to the earlier audit framing.** The T5-readiness checklist said
losing this store means "async callbacks will not work". Given T3b above, the
sharper statement is: losing it means **lifecycle events cannot be routed to SSE
clients**, because `get_by_execution` returns nothing and the forward loop
silently drops every message. That is the SPA-hang failure mode, and it is a
*T3* concern as much as a KV concern — the gateway's EHDB listener
(`event_feed.rs::forward`) has exactly the same dependency.

### Migration plan

The store is per-gateway-request routing state with a 5-minute TTL — it does not
need a distributed KV at all.

1. **Replace with an in-process map** (`DashMap<request_id, Pending>` + a TTL
   sweep), behind `NOETL_REQUEST_STORE=nats|memory`, default `nats`.
2. **The one thing to check before flipping:** multi-replica routing. If the
   gateway ever runs >1 replica, an in-process map breaks routing when the SSE
   connection and the request land on different pods. Prod runs **1 gateway
   replica** (verified), so this is safe today — but the flag must be documented
   as *incompatible with gateway replicas > 1*, and the ScaledObject/HPA checked
   before it is set.
3. If the gateway must scale out later, the right home is the same EHDB
   substrate the rest of the platform uses (an L0 KV dataset), not NATS KV.

### Parity gate

- With `memory`: drive a playbook from the SPA, confirm the client receives
  lifecycle frames end-to-end (the routing path the store exists for).
- Confirm gateway `replicas == 1` at flip time, and record it.

---

## T3d — NATS KV bucket `sessions` (gateway session cache)

### What it is

`gateway/src/session_cache.rs` — a JetStream KV bucket caching validated session
tokens with a TTL, to avoid a Postgres round-trip per request.

### Current state on prod

Bucket exists, **0 values, `Last Update: never`**. The gateway already logs
`Session cache disabled … all validations will query Postgres via NoETL API`
when NATS KV is unavailable, and **fails soft** by design.

With `NOETL_AUTH_SYNC=true` the hot path is the #168 in-process fast-path
(login 7.9 s → 0.4 s), so the cache is not carrying the latency win it was
built for.

### Migration plan

Lowest-risk of the three: the code already degrades gracefully.

1. Add `NOETL_SESSION_CACHE=nats|memory|off`, default `nats`.
2. Flip to `memory` (a TTL map) — same single-replica caveat as T3c, and the
   same mitigation.
3. Measure. If session-validate latency is unchanged versus the cache being on,
   `off` is also acceptable and removes the code.

### Parity gate

- p50/p99 of `/api/auth/validate` before and after, over the same load window.
- No increase in Postgres connection-pool saturation (the reason the cache was
  built).

---

## Suggested order

T3c and T3d are independent of T3 and can proceed in parallel with it. T3b
should start its observation window **now**, because its gate is a week of
elapsed time and it is otherwise the long pole.

```
now ──┬── T3   consumer cutover → EHDB-only → soak        (largest)
      ├── T3b  add counter → observe 1 week → delete      (elapsed-time gate)
      ├── T3c  in-process request store → verify SSE routing
      └── T3d  in-process/off session cache → verify latency
                                    ↓
                         all four green ⇒ T5 is decidable
```

T5 itself then becomes mechanical, and stays **human-gated**:

1. Remove the `nats-jetstream` KEDA trigger (already done — ops#244).
2. Remove NATS env from server / workers / writers / gateway.
3. Delete the `noetl_events` stream, then the `nats` StatefulSet + PVC.
4. Close [#188](https://github.com/noetl/ai-meta/issues/188) as retired-by-removal
   (the plaintext `noetl:noetl` credential goes with the env vars).
5. Decide separately on `nats-supercluster` — 6 pods, no workload references
   either service. Worth deleting regardless of T5, but its provenance deserves
   a question, not an assumption.

## What this file deliberately does not claim

The T3b "already dead" conclusion rests on static analysis plus a log grep. It
is strong enough to justify **measuring** rather than porting, and not strong
enough to justify deleting. The counter in step 1 is what converts it into a
fact.
