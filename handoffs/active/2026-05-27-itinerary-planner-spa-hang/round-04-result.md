---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 4
from: claude
to: claude
created: 2026-05-27T16:50:00Z
in_reply_to: round-04-prompt.md
status: partial
---

# Round 04 — Result

Status: **Phases A–C complete, Phase D blocked on wait phrase
`proceed with gateway callback state fix`**.

## Phase A — read-only audit

### A1. Re-read prior rounds

Re-read `round-03-result.md` end-to-end before starting.  Round 03
instrumentation (`gateway#13`) is live; the gateway pod
`gateway-86bdd9885f-55s8v` is running image
`instrumented-20260527083644`.

### A2. Gateway NATS receipt confirmation

Pulled gateway logs across the most recent hung chat turn (execution
`636124154944553085`, "trip to Paris"):

```
$ kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
    -n gateway logs deploy/gateway --since=30m | grep "16:25:22"
```

The Round 03 INFO log fires for every received NATS message.  Key
lines:

- `16:25:22.781816 … "event_id":636124273559470411 …`  → outbox 1567
  (`call.done` for `render_widget_chat`).
- `16:25:22.788132 … "event_id":636124273576247628 …`  → outbox 1568
  (`step.exit` for `final_result`).
- `16:25:22.795557 … "event_id":636124273601413453 …`  → outbox 1569
  (`command.completed`).
- `16:25:22.970775 … "final_step":"final_result" …`    → outbox 1572
  (`workflow.completed`, payload preview truncated past `event_type`
  because `context` precedes it).
- `16:25:22.979816 … "final_step":"final_result" …`    → outbox 1573
  (`playbook.completed`, same truncation reason).

The callback hop is logged at:

```
16:25:22.695537  Callback received: request_id=000b6470, status=COMPLETED
16:25:22.697230  Callback delivered to client: request_id=000b6470, client_id=785324d7
```

The HTTP callback delivery (697 ms) precedes the NATS
`playbook.completed` arrival (979 ms) by ~282 ms.

### A3. Outbox confirmation

Joined `noetl.outbox` against `noetl.event` for the parent
execution:

```
outbox_id  event_id              event_type            subject                                              codec          status
1574       636124275413352785    batch.completed       noetl.events.default.default.636124154944553085.0   arrow-feather  PUBLISHED
1573       636124275195248976    playbook.completed    noetl.events.default.default.636124154944553085.0   arrow-feather  PUBLISHED
1572       636124275027476815    workflow.completed    noetl.events.default.default.636124154944553085.0   arrow-feather  PUBLISHED
1568       636124273576247628    step.exit             noetl.events.default.default.636124154944553085.0   arrow-feather  PUBLISHED
…
```

(`payload_codec` column reads `arrow-feather` because that's the
on-disk storage codec; the JSON conversion happens at publish time
per Round 02's `noetl/noetl#620`.  Gateway parser accepts the JSON
fine — see the INFO log payload previews above.)

All terminal events landed in JetStream and reached the gateway.

### A4. SPA wait shape

Confirmed at
`repos/travel/src/api/noetlClient.ts:129-149`:

```ts
function handlePlaybookState(message: unknown) {
  const params = ((message as Record<string, unknown>)?.params || {}) as Record<string, unknown>;
  const executionId = String(params.execution_id || params.executionId || '').trim();
  const eventType = String(params.event_type || params.eventType || '').trim();
  if (!executionId || !eventType) return;
  if (eventType !== 'playbook.completed' && eventType !== 'playbook.failed') return;

  const pending = pendingExecutionStates.get(executionId);
  if (!pending) return;
  …
}
```

`waitForExecutionCompletion` registers
`pendingExecutionStates[executionId] = { resolve, reject }` and
resolves only on the matching `playbook/state` notification.
`handlePlaybookResult` (the `playbook/result` listener) does NOT
resolve `pendingExecutionStates`; it resolves a separate
`pendingCallbacks` map keyed by `requestId`, which the chat flow
never registers because `executeViaGatewayGraphQL` returns
immediately via `callbackFallback` when the execution_id is
present.

So the SPA's chat flow depends entirely on `playbook/state` to
exit the planning state — and the only path that emits it
(NATS listener) races + loses against the callback handler's
`request_store.remove(...)`.

## Phase B — code change

### B1. Branch

```
$ git -C repos/gateway checkout -b kadyapam/callback-emits-playbook-state
```

### B2. Edit

`repos/gateway/src/sse.rs::callback_handler`:

- Captured the resolved `execution_id` once into
  `resolved_execution_id` so it can feed both notifications.
- Computed `failed` = `callback.status == "FAILED" ||
  callback.error.is_some()`; mapped to `playbook.failed` /
  `playbook.completed` for `event_type`, and `failed` /
  `completed` for `status`.
- Built a `JsonRpcMessage::notification("playbook/state", …)` with
  fields `{execution_id, event_type, step_name: null, status, at}`
  matching what the NATS-derived state notification produces (see
  `playbook_state.rs::build_state_message`).
- Sent the state notification BEFORE the existing
  `playbook/result` send.  Logged success at INFO with
  fingerprint
  `Synthetic playbook/state delivered: request_id=…, execution_id=…, event_type=…`.
- Left the existing `playbook/result` build/send and the final
  `request_store.remove(...)` cleanup unchanged.

Diff stat: `1 file changed, 66 insertions(+), 3 deletions(-)`.

### B3. Build + test

```
$ cargo build
   Finished `dev` profile … target(s) in 10.71s
$ cargo test --quiet
test result: ok. 13 passed; 0 failed; 0 ignored; 0 measured;
              0 filtered out; finished in 0.00s
```

No new test fixtures added for the callback handler — it depends
on `SseState` (request_store + connection_hub + session_cache +
firestore_subscriptions) which lacks an existing mock harness in
this crate.  The change is a small additive write to the same
`connection_hub.send_to_client` API the result-send path already
uses, and the existing 13 tests still pass.

## Phase C — open draft PR

Pushed branch and opened the draft PR:

- **PR**: <https://github.com/noetl/gateway/pull/14>
- **Title**: `fix(sse): emit synthetic playbook/state from callback handler`
- **Status**: draft, awaiting review + merge.
- **Body**: cites the production timing evidence (697 ms vs 970 ms),
  the SPA wait shape, the round-01..04 chain, and an explicit
  post-deploy test plan (grep for the
  `Synthetic playbook/state delivered:` fingerprint).

## Phase D — live re-deploy

`phase D blocked: awaiting "proceed with gateway callback state fix"`

When the PR merges, the deploy steps are:

```bash
# 1. Rebuild image off main
cd repos/gateway
gcloud builds submit --config cloudbuild.yaml --substitutions \
  _TAG=callback-state-$(date +%Y%m%d%H%M%S) .

# 2. Helm upgrade (chart at automation/helm/gateway in noetl/ops)
helm --kube-context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  upgrade noetl-gateway repos/ops/automation/helm/gateway \
  --namespace gateway --reuse-values \
  --set image.tag=callback-state-<timestamp>

# 3. Verify
kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n gateway logs deploy/gateway --since=5m \
  | grep "Synthetic playbook/state delivered"
```

Have the user trigger one chat turn on `travel.mestumre.dev`; the
log line must appear for the new execution_id, and the SPA must
exit the planning state.

## Issues observed

- The two delivery channels (HTTP callback vs NATS lifecycle) were
  designed as independent signals carrying different data shapes
  (`playbook/result` carries the widget envelope; `playbook/state`
  carries lifecycle).  The race was latent until the SPA started
  treating one as a strict prerequisite for the other.
- `payload_codec` in the outbox table stays `arrow-feather` even
  after the Round 02 fix — that's expected, the conversion to JSON
  happens in `publish_outbox_batch`, not at insert.  Anyone
  diagnosing future hangs should not be misled by the codec column.

## Manual escalation needed

None for this round.  The fix is uncontroversial and additive.

After Phase D ships and the SPA flow is verified, the
`NOETL_INLINE_TRIVIAL_CHILDREN=enforce` re-test (Round B follow-up)
can resume — gated separately on its own wait phrase
`proceed with enforce re-test`.
