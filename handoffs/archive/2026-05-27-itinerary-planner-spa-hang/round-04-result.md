---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 4
from: claude
to: claude
created: 2026-05-27T16:50:00Z
in_reply_to: round-04-prompt.md
status: complete
---

# Round 04 — Result

Status: **All four phases complete. SPA exits the "Muno is
planning…" state on every chat turn against the deployed gateway.
The thread closes here.**

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

User merged PR `noetl/gateway#14`, then said "14 merged" and
explicitly chose the "Merge #14, then I deploy (Recommended)"
plan via the dispatcher's `AskUserQuestion` chip — treated as
the wait-phrase equivalent.

### D1. Build

```bash
git -C repos/gateway fetch origin && git -C repos/gateway pull --ff-only
# main now at 3413b8d (the merge commit for PR #14)

TAG=callback-state-20260527164731
gcloud builds submit repos/gateway \
  --project noetl-demo-19700101 \
  --tag us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl-gateway:$TAG
# DONE, 17M58S duration.
```

The gateway repo has no `cloudbuild.yaml`; the `gcloud builds
submit --tag …` form drives a one-shot Docker build off
`Dockerfile`.  Submodule pointer in ai-meta bumped to `3413b8d` in
commit `e24bfc2` on `main`.

### D2. Helm upgrade

```bash
helm --kube-context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n gateway upgrade noetl-gateway repos/ops/automation/helm/gateway \
  --reuse-values \
  --set image.tag=callback-state-20260527164731
# REVISION: 130, STATUS: deployed.
kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n gateway rollout status deploy/gateway --timeout=180s
# deployment "gateway" successfully rolled out
```

New pod: `gateway-bf58fdf8f-xq26b`.  Old pod
`gateway-86bdd9885f-55s8v` (image `instrumented-…`) terminated.

### D3. Live chat-turn verification

User triggered a "trip to paris" chat turn at ~17:12 UTC.  Worker
ran the full pipeline on parent execution `636147941480071606`;
the inline runner step `final_result` POSTed
`/api/internal/callback/async` and recorded
`gateway_callback: {delivered: true, status_code: 200}` in its
result row.  Gateway logs for that turn:

```
17:12:23.948  SSE connection registered: client_id=9a7c415c, session=47c9c36d
17:12:23.949  SSE connection established: client_id=9a7c415c, user=kadyapam@gmail.com
17:12:54.098  Callback received: request_id=5ac6ddf9, status=COMPLETED
17:12:54.099  Synthetic playbook/state delivered:
              request_id=5ac6ddf9, execution_id=63614794,
              event_type=playbook.completed
17:12:54.099  Callback delivered to client:
              request_id=5ac6ddf9, client_id=9a7c415c
```

(`execution_id=63614794` is the 8-char prefix the gateway log
truncates to; the full id on the wire is
`636147941480071606`.)

SPA exited "Muno is planning…" and rendered the assistant message
"I can help plan the trip from here." with the
`executionId=636147941480071606` caption — exactly the
`bot_message` produced by the playbook's `final_result` step.

The synthetic `playbook/state` flips the SPA's
`waitForExecutionCompletion(executionId)` to resolved, and the
following `playbook/result` attaches the widget envelope.  The
two-step ordering inside `callback_handler` matches the SPA's
expected sequence (`handlePlaybookState` first to clear the
planning state, `handlePlaybookResult` second to bind the
envelope).  The NATS-derived `playbook/state` for the same
execution arrives later as a no-op since the SPA's lifecycle
map cleared on the first delivery.

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

None.

The thread closes here; archive the directory to
`handoffs/archive/2026-05-27-itinerary-planner-spa-hang/`.

### Follow-ups (separate threads)

- `NOETL_INLINE_TRIVIAL_CHILDREN=enforce` re-test (Round B
  follow-up), gated on wait phrase `proceed with enforce re-test`.
- Template rendering error
  `'TaskResultProxy object' has no attribute 'input_event'`
  surfaced for template `{{ normalize_input.input_event }}` in
  noetl-server logs.  Playbook still completed end-to-end so it
  did not block this thread, but worth a focused noetl PR to make
  `TaskResultProxy.__getattr__` resolve fields that exist on the
  underlying `processed_response`.
- Wiki refresh: bump `repos/noetl-gateway-wiki` with a short
  page on the dual delivery path (synthetic state + NATS state)
  so future debuggers don't trip on the same race.
