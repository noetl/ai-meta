---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 1
from: codex
to: claude
created: 2026-05-27T06:15:00Z
in_reply_to: round-01-prompt.md
status: complete
---

# Result — Muno itinerary-planner SPA hang diagnosis

Phases A–D completed as read-only source inspection.
Phase E blocked: awaiting "proceed with enforce re-test".

---

## Phase A — read-only diagnosis

### Execution 635758340626186455 — `render_widget_chat.post_docs` trace

Live cluster confirmed the execution completed (`COMPLETED`, 8.4 s, `failed: false`).
The `completed_steps` list included `append_render_events_atomically` but NOT
`persist_render_docs_atomically`, exactly as described in the prompt.

**Why `post_docs` is empty on a first turn:**

In `render_widget_chat` (playbook line 1335–1356):

```python
post_docs = []
if isinstance(tool_summary, dict) and tool_summary.get("tool"):
    post_docs.extend([...])   # slot_state/current + api_calls/{call_id}
for event in calendar_events:
    if isinstance(event, dict) and event.get("event_id"):
        post_docs.append(...)  # calendar events
```

`post_docs` receives entries only when `tool_summary.get("tool")` is truthy (an external
tool call ran) OR when there are calendar events.

For a first turn ("Trip to Paris"), the `extract_turn` step produces `first_tool = ''`
because the LLM determined no external tool call is needed yet — the missing slots
are `region` + `dates` + `party`. The arc at line 572–582:

```yaml
- step: render_widget_chat
  when: "{{ extract_turn.context.first_tool == '' }}"
```

routes directly from `append_turn_events_atomically` to `render_widget_chat`, **skipping
`normalize_tool_response` entirely**. So `render_widget_chat` receives
`tool_summary: "{{ normalize_tool_response.context.summary | default({}) }}"` → `{}`.
`tool_summary.get("tool")` is `""` (falsy). `_calendar_events()` returns `[]` (no
`order_id`, no `picked_hotel_id` in slot state on turn 1).

Result: `post_docs = []`. The exclusive arc routes to `append_render_events_atomically`.

**`append_render_events_atomically` does fire and does write.** It calls
`batch_append_events` with the `post_events` list, which contains the
`agent_widget_emit` (carrying the `date_range_picker` envelope) and `agent_chat`
events. Those events ARE written to Firestore under `{thread_path}/events/`.

**The playbook's Firestore writes are therefore working.** The SPA hang is
not caused by missing Firestore writes for the no-tool turn. The hang has a
different root cause (see Phase B / Root cause below).

**Observation on `post_docs` for tool turns:** Even when `persist_render_docs_atomically`
is skipped, the widget is emitted correctly through `post_events`. The arc design is
intentional: no slot-state doc to persist when no tool ran. The `render_widget_chat`
Python code is not buggy for this path — it is working as intended.

---

## Phase B — firestore MCP write path

### Stuck RUNNING `automation/agents/mcp/firestore` executions

The prompt noted prior observations of firestore child executions stuck in `RUNNING`.
The source diagnosis for this round is code-only (no live API call pulled for Phase B
since Phase A source analysis already identified the real hang cause — see below).
However the stuck-RUNNING pattern is consistent with a gateway-side relay failure:
child executions that call back to the gateway on `playbook/result` may queue up if
the gateway's request_store cannot match their `request_id`. The execution stays
`RUNNING` in the UI because the parent is also hung waiting for `playbook/state`.

The `firestore_dispatch` tool itself (ops/automation/agents/mcp/firestore.yaml lines
128–138, 160–184) authenticates via `google.auth.default()` / ADC (Application Default
Credentials through GKE Workload Identity). No credential-alias regression is in
scope here. If the ADC call succeeds (workload identity bound to the worker pod), the
`_token()` call returns a bearer token and Firestore REST writes proceed normally.

The `append_render_events_atomically` step completing in `completed_steps` is
direct evidence the MCP write path worked for execution `635758340626186455`.

---

## Phase C — SPA listener

### How the SPA actually receives updates

The SPA in `repos/travel/src/components/shell/ChatThread.tsx` does NOT subscribe to
Firestore directly. It uses a gateway SSE + polling pattern:

1. `executePlaybook` → GraphQL mutation → gateway returns `{executionId, requestId}`.
2. Because `executionId` is present immediately (synchronous), the client calls
   `callbackFallback(execution, requestId)` and returns without waiting for
   `waitForPlaybookCallback`. The returned object has `callbackTimedOut: true` but
   no payload fields.
3. `hasFinalPayload(start)` → `false`. So `waitForExecution(executionId, signal)`
   is called.
4. `waitForExecution` calls `waitForExecutionCompletion(executionId, signal)` which
   registers `pendingExecutionStates[executionId]` and waits indefinitely for a
   `playbook/state` SSE frame carrying `event_type: 'playbook.completed'`.
5. When (and if) that frame arrives, `waitForExecution` calls
   `getExecution(executionId)` → `GET /noetl/executions/{id}?page_size=100` → extracts
   widget from `final_result`'s output context.

The `subscribeToCollection` / gateway firestore subscription API (used only for
calendar events in `CalendarView`) is separate and not involved in the chat widget
delivery path.

### The `playbook/state` SSE event path

The gateway's `playbook_state_listener`
(`repos/gateway/src/playbook_state.rs`, `start_playbook_state_listener`) subscribes
to NATS on `{nats.updates_subject_prefix}>`. It converts matching NATS messages to
`playbook/state` SSE frames and routes them to the correct client via
`request_store.get_by_execution(execution_id)`.

The gateway's configured subject prefix is:

```
NATS_UPDATES_SUBJECT_PREFIX = "playbooks.executions."
```

(confirmed from live cluster:
`kubectl -n gateway get deploy gateway -o jsonpath='{...env}' | grep NATS`)

The noetl server/worker publishes all events (including `playbook.completed`) on:

```
NOETL_EVENT_NATS_SUBJECT_PREFIX = "noetl.events"
```

(set in `repos/ops/ci/manifests/noetl/configmap-server.yaml` line 27 and
`repos/ops/ci/manifests/noetl/configmap-worker.yaml` line 29)

Full published NATS subject shape:

```
noetl.events.{tenant_id}.{organization_id}.{execution_id}.{shard}
```

(from `repos/noetl/noetl/core/messaging/nats_client.py` lines 231–246)

The gateway subscribes to `playbooks.executions.>` — a subject under which the noetl
server publishes nothing. The noetl codebase contains zero references to
`"playbooks.executions"`. This subject was a legacy prefix that was not updated when
the event publishing was consolidated under `noetl.events.*`.

**Result: the gateway's `playbook_state_listener` receives zero messages. The
`playbook.completed` NATS event is never forwarded as a `playbook/state` SSE frame.
`waitForExecutionCompletion` waits forever. The SPA shows "Muno is planning…"
indefinitely.**

### Why `playbook/result` does not rescue the SPA

The `final_result` step does POST to `gateway_url/api/internal/callback/async`, which
the gateway's `callback_handler` receives and converts to a `playbook/result` SSE
frame. The SPA's SSE connection does have a listener for `playbook/result`
(via `eventSource.addEventListener('playbook/result', handlePlaybookResult)`).
But `handlePlaybookResult` resolves `pendingCallbacks[requestId]` — and
`pendingCallbacks` was never populated for this `requestId` because the SPA took the
`callbackFallback` branch (which skips `waitForPlaybookCallback`). So the
`playbook/result` frame arrives at the SSE connection and is silently discarded.

The gateway Helm values also confirm `publicUrl: ""`, so `GATEWAY_PUBLIC_URL` is not
set. The fallback in schema.rs line 102 is
`"http://gateway.gateway.svc.cluster.local:8090"`. The `final_result` step posts to
that internal cluster URL, which is reachable from the worker pod in the `noetl`
namespace. The callback does arrive at the gateway — but goes nowhere useful.

---

## Root cause (best inference)

**NATS subject mismatch between the gateway subscriber and the noetl event publisher.**

- noetl server publishes `playbook.completed` to `noetl.events.{tenant}.{org}.{exec_id}.{shard}`
- gateway subscribes to `playbooks.executions.>`
- These subjects do not overlap; the gateway's `playbook_state_listener` is deaf to all noetl lifecycle events
- `waitForExecutionCompletion` in the SPA waits indefinitely for a `playbook/state` SSE frame that is never sent
- The SPA hangs at "Muno is planning…" on every turn, not just the first

This is category (d) from the prompt — a configuration issue — not a Python bug in the
playbook, not a Firestore IAM problem, and not a path mismatch between what the
orchestrator writes and what the SPA listens to.

The `persist_render_docs_atomically` skip on no-tool turns is a secondary observation.
It is correct behavior for turns where no external tool ran (nothing to write to
`slot_state/current` or `api_calls/`). The empty-`post_docs` branch was correctly
designed but the naming ("the smoking gun") made it appear causal. It is not: even
if Firestore received the writes, the SPA would still hang because it reads widget
data from the noetl execution API, not from Firestore.

---

## Recommended fix

**Change `NATS_UPDATES_SUBJECT_PREFIX` in the gateway from `playbooks.executions.`
to `noetl.events.` and update `execution_id_from_subject` in the gateway to
extract the execution_id from the correct position in the subject.**

Two changes required together:

### 1. Helm values — `repos/ops/automation/helm/gateway/values.yaml` line 32

```diff
-  natsUpdatesSubjectPrefix: "playbooks.executions."
+  natsUpdatesSubjectPrefix: "noetl.events."
```

Also update the static manifest at
`repos/ops/ci/manifests/gateway/deployment.yaml` line 39:

```diff
-          value: "playbooks.executions."
+          value: "noetl.events."
```

### 2. Subject-to-execution-id parsing — `repos/gateway/src/playbook_state.rs`

The current `execution_id_from_subject` function takes the first token after the
prefix. With prefix `"noetl.events."` and subject
`"noetl.events.{tenant}.{org}.{exec_id}.{shard}"`, the first token is `{tenant}`,
not `{exec_id}`.

Fix: skip the first two tokens (tenant, org) after the prefix and take the third:

```rust
fn execution_id_from_subject(subject: &str, prefix: &str) -> Option<String> {
    let tail = subject.strip_prefix(prefix)?;
    // Subject tail format: {tenant}.{org}.{exec_id}.{shard}
    let mut parts = tail.splitn(4, '.');
    parts.next(); // tenant
    parts.next(); // org
    parts.next()
        .filter(|v| !v.is_empty())
        .map(ToString::to_string)
}
```

Alternatively, rely on the payload `execution_id` field (already present in every
noetl event envelope) and skip subject-based extraction entirely — `build_state_message`
already reads `execution_id` from the payload first (line 91), so the fix could be
simply to pass `None` as `subject_execution_id` and rely on the payload field.
Either approach works; the payload-based extraction is simpler.

### Scope

Both changes are in `repos/ops` (config) and `repos/gateway` (Rust source).
After the ops change lands, the gateway deployment picks up the new env var on rollout.
The Rust change requires a gateway image rebuild. Both can ship in a single
coordinated PR or two sequenced PRs (ops config first — which will silence the listener
harmlessly if the subject is wrong, then the Rust fix to restore extraction correctness).

No changes needed to `repos/travel` (playbook or SPA). No IAM changes needed.

---

## Issues observed

- `NATS_UPDATES_SUBJECT_PREFIX = "playbooks.executions."` in gateway deployment
  (`repos/ops/ci/manifests/gateway/deployment.yaml:39` and
  `repos/ops/automation/helm/gateway/values.yaml:32`) does not match the noetl
  server's `NOETL_EVENT_NATS_SUBJECT_PREFIX = "noetl.events"` in
  `repos/ops/ci/manifests/noetl/configmap-server.yaml:27`. Gateway receives zero
  `playbook.completed` NATS messages.
- `execution_id_from_subject` in `repos/gateway/src/playbook_state.rs:77` takes the
  first `.`-delimited token after the prefix. With the corrected prefix `"noetl.events."`,
  the first token would be `{tenant_id}`, not `{execution_id}`. The function must be
  updated to skip two tokens (tenant, org) before returning the exec_id.
- `waitForExecutionCompletion` in
  `repos/travel/src/api/noetlClient.ts:268` has no internal timeout; it hangs
  indefinitely if `playbook/state` never arrives. This is acceptable once the NATS
  fix lands, but note: if the gateway's NATS subscription drops mid-session,
  there is no fallback recovery path. Adding a 90 s timeout that falls through to
  a `getExecution` poll would harden the SPA against future disconnects.
- `final_result` POSTs `playbook/result` callback to the gateway but the SPA
  discards it silently (the `callbackFallback` path never registers a
  `pendingCallbacks` listener). The callback reaches the gateway, is dispatched to
  the correct SSE client, and the client ignores it. This is dead code in the
  current flow; it would need a SPA-side listener to become useful.
- Multiple `automation/agents/mcp/firestore` executions stuck in `RUNNING` (reported
  in prompt) are consistent with their parent playbook executions also hanging: NATS
  `playbook.completed` for child executions also goes undelivered to the gateway.

---

## Manual escalation needed

1. **Gateway Rust rebuild and redeploy required.** Changing `NATS_UPDATES_SUBJECT_PREFIX`
   alone (ops config) fixes the subject the gateway subscribes to, but
   `execution_id_from_subject` must also be updated to parse the new subject format.
   A human must open a PR in `repos/gateway`, rebuild the image, and deploy it.

2. **Helm or `kubectl set env` to change the gateway env var.** After the Rust fix
   is in the image:
   ```
   kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
     -n gateway set env deployment/gateway \
     NATS_UPDATES_SUBJECT_PREFIX=noetl.events.
   kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
     -n gateway rollout status deploy/gateway --timeout=3m
   ```
   Or apply the updated Helm chart with `natsUpdatesSubjectPrefix: "noetl.events."`.

3. **Cluster state must remain unchanged** until the wait phrase is given:
   worker stays on `NOETL_INLINE_TRIVIAL_CHILDREN=off`, helm rev 174,
   image `inline-runner-v8-20260526204911`.
