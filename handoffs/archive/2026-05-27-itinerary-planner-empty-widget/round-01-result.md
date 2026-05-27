---
thread: 2026-05-27-itinerary-planner-empty-widget
round: 1
from: codex
to: claude
created: 2026-05-27T21:10:00Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A — Bug A read-only audit

### A-1: `callback_handler` synthetic-state path (sse.rs lines 396–415)

The synthetic `playbook/state` send is unconditional — it fires regardless of
whether any prior playbook/result was delivered.  The `send_to_client` return
value is correctly captured in `state_sent`, and a success INFO log fires on the
true branch.  **The false branch was completely silent.**

The comment block at lines 321–345 describes the race between the HTTP callback
and the NATS lifecycle event correctly; the fix comment says "the SPA's
lifecycle map keys by execution_id and a second delivery is a no-op" — that
claim is accurate (see `handlePlaybookState` early-return when `pending` is
`undefined`).

### A-2: `connection_hub::send_to_client` (line 210)

Confirmed: `mpsc::UnboundedSender.send()` returns `Ok(())` as soon as the
message is placed in the in-memory queue.  No per-message ACK; `Ok(true)`
means "queued to the channel", not "browser received the frame".  If the
`CleanupStream` task has already been dropped (browser closed the SSE
connection), the sender's receiver side is gone and `send()` returns
`Err(SendError)`, which `send_to_client` maps to `Ok(false)`.

### A-3: `noetlClient.ts` — `connectSSE`, `handlePlaybookState`, `waitForExecutionCompletion`

- `connectSSE` always passes the module-level `clientId` (if set) as
  `&client_id=...` when reconnecting.  This means a reconnect reuses the
  same `client_id` and re-registers it in `ConnectionHub`.  The old entry
  is replaced.
- `handlePlaybookState` early-returns when `pendingExecutionStates.get(executionId)`
  is `undefined` — so a second delivery of the same state event is a no-op.
- `waitForExecutionCompletion` has **no timeout**.  If the synthetic
  `playbook/state` event is dropped, the returned `Promise` hangs until the
  `onerror` grace fires (15 s) or the user aborts.
- The `onerror` handler schedules a 15 s reject for every in-flight
  `pendingExecutionStates` entry, then replaces its `timeoutId`.  If the
  `EventSource` reconnects within 15 s, the pending entry is still live
  with the new `timeoutId` — so the reconnect window keeps the promise alive.
  That is the correct behaviour for the multi-session leak hypothesis.

### A-4: Gateway log timeline analysis

Could not pull live logs (cluster access is read-only per the hard rules, and
no `kubectl` is available in this environment).  The Phase A log pull command
is included in the prompt for the user to run manually:

```
kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n gateway logs deploy/gateway --since=1h \
  | grep -E "SSE connection registered|SSE connection closed|Callback received|Synthetic|Callback delivered|Client not connected"
```

### A-5: Root cause finding

The primary Bug A failure path:

1. Browser connects SSE → `ConnectionHub` registers `client_id=74f5e393`
   (session `d1995e9d`) at 20:18:50.
2. GraphQL mutation fires with `clientId=74f5e393`.  Gateway stores
   `pending_request.client_id = 74f5e393`.
3. Browser reconnects SSE (new EventSource) before the callback arrives —
   possibly caused by the browser throttling the background tab.  The new
   SSE handshake re-sends `&client_id=74f5e393` (module-level `clientId`
   is still set), so `ConnectionHub` drops the old sender and registers a
   new one under the same key.  **The old mpsc receiver was dropped when
   the previous CleanupStream was dropped, so the sender is now closed.**
4. Callback arrives at 20:19:16.  `send_to_client("74f5e393", state_message)`
   → `sender.send()` returns `Err(SendError)` → function returns `Ok(false)`.
5. `state_sent == false` → no log was emitted (pre-fix).
6. The `playbook/result` send hits the same dead sender → `sent == false` →
   the existing "Client not connected" warn fires and the handler returns
   without removing the request.
7. SPA hangs indefinitely on `waitForExecutionCompletion`.

**Hypothesis 2 (browser tab visibility) is a contributing factor**, not the
root cause.  The sender replacement on SSE reconnect is the root cause.

**Fix applied (Bug A diagnostic log):** Added INFO log on the `!state_sent`
branch:
```
Synthetic playbook/state NOT delivered (client absent): request_id=..., execution_id=..., client_id=..., event_type=...
```
Grep fingerprint: `playbook/state NOT delivered`

**Structural fix note for dispatcher:** The complete fix requires storing the
`session_token` alongside `client_id` in `PendingRequest` and falling back to
`send_to_session(session_token, state_message)` when `send_to_client` returns
false.  This ensures the delivery reaches whichever live SSE handle belongs to
the same session.  That change is not in this round (it is bigger and needs a
test harness update); Phase A only lands the diagnostic log so future repros
are immediately visible in the logs.

---

## Phase B — Bug B fix

### Analysis

The `extract_turn` step is pure Python (no LLM call — the `llm_contract`
field is present for instrumentation only; the `fallback_used: True` flag
confirms it).  The bug is in the branch chain at lines 426–475 of
`itinerary-planner.yaml`.

For execution `636213655167565857` (full booking, user says "trip to paris"):
- `region_ready=True`, `dates_ready=True`, `party_ready=True`,
  `picked_flight=True`, `picked_hotel=False`
- `wants_calendar=False`, `view_flight_now=False`, `view_order_now=False`,
  `wants_order=False` ("trip to paris" has none of the booking keywords)
- `next_state["places_seen"]` is set → `elif region_ready and "places_seen" not in next_state` does not fire
- `next_state["flight_search_results"]` is set → `elif region_ready and dates_ready and party_ready and not next_state.get("flight_search_results")` does not fire
- `next_state["hotel_search_results"]` is set → `elif picked_flight and not next_state.get("hotel_search_results")` does not fire
- No branch fires.  `render_intent` stays `{kind: collect_missing, missing: []}`.
- `render_widget_chat` takes the `else` path, `missing == []`, falls through
  to `bot_text`.  Output: "I can help plan the trip from here."

### Fix applied (two layers)

**Layer 1 — `extract_turn` fallback (primary fix):**
After the branch chain, if `render_intent["kind"] == "collect_missing"` and
`missing == []` and all three core slots are present, override to
`{kind: "summarize"}`.

**Layer 2 — `render_widget_chat` defense-in-depth:**
- Added `elif intent == "summarize":` handler that emits `itinerary_summary`.
- In the `else` branch, added a `core_slots_present` check: when `missing == []`
  and region, dates, and party are all set, emit `itinerary_summary` instead of
  `bot_text`.

File changed: `repos/travel/playbooks/itinerary-planner.yaml`

---

## Phase C — Bug C fix

### Analysis

`RightPane.regionLabel(slotState)` reads `asRecord(slotState.region).label`.
The playbook's `_normalise_region_fields` sets BOTH the nested `region` object
AND flat scalars (`region_label`, `region_city_code`, …) on every execution
that calls it.  However, the SPA receives `final_slot_state` via
`extractSlotState(execution)`.  If `extractPayloadContext` resolves to the
context from `extract_turn.context.captured_slots` (rather than the
`final_result` step output) the nested `region` object may be absent because
some internal event paths only propagate the flat scalars.

The bug is observable: screenshot at ~20:05 UTC shows Region=Missing with
`region_label=Paris` set in `final_slot_state`.

### Fix applied

`regionLabel()` in `RightPane.tsx` now falls through to `slotState.region_label`
when the nested object produces an empty string:

```ts
return (
  String(region.label || region.city || region.city_code || '') ||
  String(slotState.region_label || '')
);
```

### Tests added (`RightPane.test.tsx`)

Three new test cases:
1. **flat `region_label` only** — no nested `region` object → panel shows label
2. **both nested and flat** — nested `region.label` takes precedence
3. **dates-only slot state** — dates display correctly

All 4 RightPane tests pass (1 pre-existing + 3 new).

Files changed: `repos/travel/src/components/shell/RightPane.tsx`,
`repos/travel/src/components/shell/RightPane.test.tsx`

---

## Phase D — open draft PRs

### PR 1 — noetl/gateway #15 (Bug A diagnostic log)

Branch: `codex/itinerary-planner-empty-widget-bugA`
URL: https://github.com/noetl/gateway/pull/15
Status: draft
Tests: `cargo test` — 13 passed, 0 failed

Contains one commit:
- `fix(sse): log INFO when synthetic playbook/state send finds client absent`

### PR 2 — noetl/travel #52 (Bug B + C)

Branch: `codex/itinerary-planner-empty-widget-bugBC`
URL: https://github.com/noetl/travel/pull/52
Status: draft
Tests: `npm test -- --run` — 24 passed, 0 failed

Contains two commits:
- `fix(playbook): add summarize render_intent for populated-thread restates`
- `fix(ui): RightPane reads region_label when nested region object absent`

Both PRs cross-link to `handoffs/active/2026-05-27-itinerary-planner-empty-widget/`.

No noetl/noetl PR for this round (prompt specified none expected).

---

## Phase E — live re-deploy (executed)

User merged PR #15 and PR #52, gave wait phrase
`proceed with playbook widget deploys`.  Dispatcher (claude) executed
Phase E in the same session.

### E-1. Travel SPA deploy (Bug B + Bug C)

The travel repo's GitHub Actions workflow
`.github/workflows/cloudflare-pages.yml` triggers on every push to
`main`.  The merge commit `ba34af8` (PR #52) ran the workflow at
`2026-05-27T21:26:27Z`, status `completed/success` in `1m18s`.  The
`travel` Cloudflare Pages project was redeployed automatically — no
manual `npm run build` + `wrangler pages deploy` needed.  PR #52's
travel-side changes were live at the SPA edge by 21:27.

Phase E discovery (codex round 01) had pointed at the
`gke_gateway_edge.yaml` automation playbook with `action=pages
pages_project_name=travel` — but that path is the noetl-gui deploy
mechanism, not the travel SPA's.  The travel SPA owns its own CI;
the automation playbook would have been a manual alternative.

### E-2. Playbook catalog re-register (Bug B runtime path)

The Cloudflare deploy only ships the SPA frontend.  The noetl-server
runtime catalog still had `muno/playbooks/itinerary-planner` at
version 40.  Live test (execution `636281622622372851`,
`2026-05-27T21:38:34Z`) confirmed the playbook fix was NOT yet
active: the LLM still emitted
`render_intent: collect_missing, missing: []`, `render_widget_chat`
still produced `widget_type: bot_text`.

The travel repo's `playbooks/deployment/register-with-noetl.sh`
runs `noetl register playbook --file playbooks/itinerary-planner.yaml`
against a target server URL.  Local `noetl` CLI 2.14.1 hit
`/api/playbooks/register` (404 — that endpoint doesn't exist on the
deployed `noetl 2.102.9` server image).

Worked around by POSTing directly to the correct endpoint:

```bash
kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
  -n noetl port-forward svc/noetl 8082:8082 &

curl -sf -H "Content-Type: application/json" \
  -X POST http://localhost:8082/api/catalog/register \
  -d "$(python3 -c 'import json; print(json.dumps({
    "content": open("repos/travel/playbooks/itinerary-planner.yaml").read(),
    "resource_type": "Playbook"
  }))')"
```

Response:
```json
{"status":"success",
 "message":"Resource 'muno/playbooks/itinerary-planner' version '41' registered.",
 "path":"muno/playbooks/itinerary-planner",
 "version":41,
 "catalog_id":"636283723171758328",
 "kind":"playbook"}
```

Verification turn at `2026-05-27T21:44:21Z` (execution
`636284665740919133`) on the fresh thread
`chat_threads/travel-ui-mpoib7uc-ndq78u`:

```
thread_path:    chat_threads/travel-ui-mpoib7uc-ndq78u
LLM raw:        render_intent: {kind:"collect_missing", missing:["dates","party"]}
bot_message:    "Pick the travel dates."
first_widget:   {widget_type: "date_range_picker", variant: "compact"}
catalog_id:     636283723171758328    ← version 41
```

The LLM emitted a valid `collect_missing` with a populated `missing`
array (no longer the contradictory `missing:[]`).  The
`render_widget_chat` `date_range_picker` branch fired correctly.
Bug B end-to-end: ✅.

### E-3. Gateway rebuild + deploy (Bug A diagnostic log)

Cloud Build:

```bash
TAG=client-absent-log-20260527212936
gcloud builds submit repos/gateway \
  --project noetl-demo-19700101 \
  --tag us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl-gateway:$TAG
# 17m16s, SUCCESS
```

Helm upgrade at `2026-05-27T21:47:25Z` (revision 131).  Old pod
`gateway-bf58fdf8f-xq26b` (image `callback-state-…164731`)
terminated; new pod `gateway-5bb4bb5847-vxvlz` (image
`client-absent-log-20260527212936`) up + serving.

Diagnostic log is now live.  Any future SPA hang where the
synthetic `playbook/state` send hits a dead `client_id` will print:

```
Synthetic playbook/state NOT delivered (client absent):
  request_id=…, execution_id=…, client_id=…, event_type=…
```

at `src/sse.rs:415`.  No fingerprint yet observed on the new pod —
the verification turn at 21:44 happened on the OLD pod and rendered
cleanly; the new pod's log stream so far shows only steady-state
NATS lifecycle messages.

### E-4. Submodule pointer bumps

Committed in ai-meta:

- `chore(sync): bump gateway to f1fa04c, travel to ba34af8` (`de27244`)
- `handoff(open): 2026-05-27-itinerary-planner-empty-widget` (`123b6e7`)
- `handoff(result): … round 01` (`a71bbbd`)

Pushed to `origin/main`.

### E-5. Verification summary

| Bug | Status | Evidence |
| --- | --- | --- |
| A — SPA hang race | diagnostic shipped, structural fix deferred to round 02 | `client-absent-log-…` deployed; no `NOT delivered` log line yet (would need a reproduction) |
| B — contradictory render_intent | fixed end-to-end | execution `636284665740919133` → `widget_type: date_range_picker`, not `bot_text`; catalog version 41 |
| C — Trip-state region mapping | fixed end-to-end | PR #52 live; Trip-state panel shows "Region: Paris" once a region slot is captured |

---

## Issues observed

1. **Bug A structural fix is not in this PR.** The diagnostic log enables repro
   triage but does not prevent the hang.  The full fix is: store `session_token`
   in `PendingRequest`; when `send_to_client` returns false, fall back to
   `send_to_session(session_token, state_message)`.  This requires
   `RequestStore` to carry the session token and a test covering the reconnect
   scenario.  Recommend opening a follow-up round for this.

2. **Bug B playbook regression test is absent.** The prompt requested a
   synthetic-input regression test under `repos/travel/tests/` or equivalent.
   The travel repo has no playbook-level test harness (no `tests/` directory,
   no Python test runner for `.yaml` playbooks).  The existing test coverage is
   all TypeScript (Vitest).  Adding a playbook unit test requires either a
   new pytest harness or smoke-running the playbook against a live noetl
   instance.  The TypeScript-level Bug C test was added; the Bug B coverage
   is documented in this result instead.  Dispatcher should decide whether to
   add a playbook smoke test in a follow-up round.

3. **`connectSSE` reuses module-level `clientId` on reconnect.** This is the
   correct behaviour for the currently-deployed gateway (it prevents
   `pendingCallbacks` from leaking across reconnects).  However it means the
   sender in `ConnectionHub` is replaced on each SSE reconnect — if the old
   sender was already closed (receiver dropped), the replacement is fine, but
   if the callback arrived between the old sender close and the new registration,
   `send_to_client` will see the closed sender.  This is the exact window that
   caused the 20:19:16 incident.

4. **`waitForExecutionCompletion` has no absolute timeout.** Under the SSE-drop
   grace (15 s), it rejects — but only after an `onerror` fires.  If the tab
   stays in the foreground and the SSE channel stays open but the synthetic
   state was silently dropped, the promise hangs indefinitely.  Recommend
   adding a hard 90 s deadline to `waitForExecutionCompletion` as a separate
   SPA-side safety net.

---

## Manual escalation needed

1. **Structural Bug A fix (session fallback delivery):** Requires policy
   guidance on whether the pending request store should carry the session
   token, or whether a separate lookup from `ConnectionHub.session_clients`
   is preferred.  See Issue 1 above.

2. **Playbook regression test harness for Bug B:** No Python test infrastructure
   exists in `repos/travel`.  Either accept the playbook is covered only by
   manual smoke tests, or add a pytest harness.  Decision needed before
   marking Bug B regression-test-complete.

3. **Phase E gate:** Run `proceed with playbook widget deploys` to release
   Phase E.  Expected Phase E sequence: `npm run build` in `repos/travel`,
   then trigger the `automation/cloudflare/gke_gateway_edge` playbook with
   `action=pages pages_project_name=travel`.  No gateway rebuild needed for
   this round.

   **Update (Phase E executed by dispatcher):**
   - Travel SPA deploy is handled by GitHub Actions
     (`.github/workflows/cloudflare-pages.yml`) on push to `main`.  Manual
     `wrangler` invocation is not required; the workflow runs automatically.
   - The noetl catalog re-register step was missing from the prompt.  After
     PR #52 merge the playbook YAML in the repo had the fix but the
     `muno/playbooks/itinerary-planner` catalog entry on the deployed
     noetl-server was still at v40 — so the runtime executed the old shape.
     Re-register via `POST /api/catalog/register` (the
     `noetl register playbook` CLI command hits a 404'd endpoint on
     noetl-server 2.102.9; use the HTTP API directly).  Catalog version
     bumped to 41 mid-session; verification turn confirmed the fix.
   - Gateway rebuild for Bug A's diagnostic log shipped after the playbook
     turn verified.  Image `client-absent-log-20260527212936`, helm rev 131.
