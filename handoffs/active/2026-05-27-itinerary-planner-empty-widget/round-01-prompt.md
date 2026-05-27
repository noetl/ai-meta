---
thread: 2026-05-27-itinerary-planner-empty-widget
round: 1
from: claude
to: codex
created: 2026-05-27T20:25:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "proceed with playbook widget deploys"
---

# Round 01 — Itinerary planner empty-widget arc: SPA hang race, contradictory render_intent, missing slot mapping

> **Predecessor:** the SPA-hang thread closed in
> [`handoffs/archive/2026-05-27-itinerary-planner-spa-hang/`](../../archive/2026-05-27-itinerary-planner-spa-hang/).
> Re-read `round-04-result.md` there for the gateway transport
> chain that's now solid — it explains why every server-side
> delivery in the new bugs looks correct.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`.  Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`, `agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose),
`agents/rules/logging.md` (no INFO on hot paths), and
`agents/rules/submodules.md`.

Three application-layer bugs surfaced after the gateway transport
chain was sealed.  All three are reproducible against the live
`travel.mestumre.dev` SPA and the `noetl-demo-19700101` GKE cluster.

## Bug A — SPA hangs intermittently on "Muno is planning…" despite synthetic state delivery

### Symptom

User types "trip to Paris", chat shows "Muno is planning…" and
stays there for minutes.  Server-side timeline for the most
recent reproduction (execution `636241779972375028`,
2026-05-27T20:19 UTC):

```
20:18:50.097  SSE connection registered: client_id=74f5e393, session=d1995e9d
20:19:16.303  Callback received: request_id=d1cae609, status=COMPLETED
20:19:16.304  Synthetic playbook/state delivered:
              request_id=d1cae609, execution_id=63624177,
              event_type=playbook.completed
20:19:16.304  Callback delivered to client:
              request_id=d1cae609, client_id=74f5e393
20:19:16.600  Workflow completed: execution_id=636241779972375028
20:19:16.600  Playbook completed
```

Server-side the synthetic `playbook/state` was sent to client
`74f5e393` at `20:19:16.304`.  The SPA UI never exited the
planning state.  No SSE disconnect logged for `74f5e393` in the
window.

### Pre-context

- Gateway image `callback-state-20260527164731` is deployed
  (gateway pod `gateway-bf58fdf8f-xq26b`).  Source includes
  `noetl/gateway#14` — `callback_handler` synthesizes
  `playbook/state` and sends to `connection_hub.send_to_client`
  before the request_store remove.
- noetl image `proxy-context-20260527173650` (noetl/noetl#621
  merged).  `TaskResultProxy` now falls back to
  `data["context"][name]` for compaction-stripped fields.
- SPA at `repos/travel/src/api/noetlClient.ts` — see
  `handlePlaybookState` (line ~129) and
  `waitForExecutionCompletion` (line ~268).  Listens on
  `eventSource.addEventListener('playbook/state', …)`.
- SPA's chat is in `repos/travel/src/components/shell/ChatThread.tsx`
  — `runTurn` awaits `waitForExecution(executionId, signal)` and
  the `"Muno is planning…"` lottie is gated on `submitting`.
- There is NO timeout in `waitForExecutionCompletion` — it
  resolves only on a matching `playbook/state` event (or rejects
  via abort / SSE drop grace 15s).
- Across reproductions the SPA sometimes does eventually render,
  sometimes hangs forever.  The latency between callback and
  render is wildly inconsistent.

### Hypotheses to test

1. **Multi-session SSE leak.**  The gateway log shows two
   distinct `session=` ids in a short window (`99066152` at
   20:18:10, `d1995e9d` at 20:18:50).  The browser
   `EventSource` is created against the *current* session, but
   the gateway may still have the previous SSE handle in
   `ConnectionHub` since no "SSE connection closed" line fired
   for `client_id=5db32108`.  If the GraphQL mutation
   `clientId` parameter ever points to the stale client, the
   gateway delivers the synthetic state to a dead handle and
   nothing reaches the browser.
2. **Browser tab visibility.**  Browsers can throttle background
   tabs and even pause `EventSource` message dispatch.  If the
   user moved focus mid-execution the SSE frames are queued
   but `addEventListener('playbook/state', …)` may not fire
   until refocus.
3. **`pendingExecutionStates` key mismatch.**  Both sides
   originate from the same noetl-server response so this
   *should* be impossible, but worth a paranoid INFO log on
   both sides to confirm exact equality.
4. **SSE `onerror` race with `setTimeout(reject, 15_000)`.**
   `noetlClient.ts` schedules a reject 15s after an `onerror`
   fires.  If the EventSource drops + reconnects in that
   window, the inflight `pendingExecutionStates` entry is
   rejected even though a fresh subscription is now live.

### Phase A — Bug A read-only audit

1. Re-read `repos/gateway/src/sse.rs::callback_handler` (lines
   ~290-450) end-to-end.  Confirm the synthetic state path is
   unconditional and the `send_to_client` return value is
   ignored for telemetry only.
2. Re-read `repos/gateway/src/connection_hub.rs::send_to_client`
   (line ~210).  Confirm there's no per-message
   acknowledgement — `mpsc::UnboundedSender.send` returns Ok
   the instant the message is queued, not when the client
   receives it.
3. Read `repos/travel/src/api/noetlClient.ts` end-to-end.
   Focus on `connectSSE`, `handlePlaybookState`,
   `waitForExecutionCompletion`, and the `eventSource.onerror`
   handler.
4. Pull gateway logs since the latest deploy:
   ```
   kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
     -n gateway logs deploy/gateway --since=1h \
     | grep -E "SSE connection registered|SSE connection closed|Callback received|Synthetic|Callback delivered|Client not connected"
   ```
   Build a timeline of every SSE register / close + every
   callback delivery and look for client_id collisions where
   the message went to an SSE that closed before the browser
   could consume it.
5. Add a server-side counter / log in
   `connection_hub::send_to_client` that logs the result
   (`Ok(true)` vs `Ok(false)`) at INFO when invoked from
   `callback_handler`'s synthetic-state send.  The current
   path only logs the success message *after* `send_to_client`
   succeeded; the false branch is silent.  (This is bounded
   by playbook lifecycle, so INFO is acceptable per
   `agents/rules/logging.md`.)

## Bug B — LLM emits `render_intent: collect_missing` with empty `missing: []`

### Symptom

After the SPA receives the synthetic state and renders the
assistant message, the response is always:

> "I can help plan the trip from here."

with `widget_type: bot_text`.  The playbook captured all slots
correctly, but `render_widget_chat` selected the generic
fallback because `extract_turn`'s LLM produces a contradictory
`render_intent`.

### Evidence

For execution `636213655167565857` (one of many reproductions),
the LLM raw response stored in the `extract_turn` step's
`call.done` event:

```json
{
  "slot_updates": {"region": {"label":"Paris","city_code":"PAR",
                             "country_code":"FR","kind":"city"}},
  "tool_requests": [],
  "render_intent": {"kind": "collect_missing", "missing": []}
}
```

`render_intent.kind == "collect_missing"` with `missing == []`
is nonsensical — "collect what's missing" with nothing missing.
`render_widget_chat` honors `render_intent.kind` literally and
falls into the `bot_text` branch.

`captured_slots` for the same execution shows the thread is
already fully populated from prior turns:

```
region_label=Paris, region_city_code=PAR,
check_in_date=2026-06-17, check_out_date=2026-06-21, nights=4,
order_id=ord_0000B6PNBIJrIN9d18GSEC,
booking_reference=TUILUK,
picked_flight_offer_id=off_0000B6PN49SwCer4MIskXa, …
```

The LLM is being asked to extract from a thread that already has
a full booking.  It correctly only emits the region update (user
typed "trip to paris"), but doesn't know what to do for
`render_intent` so it defaults to `collect_missing,missing:[]`.

### Phase B — Bug B fix

6. Read the LLM system prompt for `extract_turn` in
   `repos/travel/playbooks/itinerary-planner.yaml`
   (around line 142 onward — the python `tool.code` block,
   look for `system_prompt =` or `prompt =`).  Identify the
   instruction that tells the model how to pick
   `render_intent.kind`.
7. Patch the prompt so the model has a clear rule when
   `loaded_slot_state` is fully populated and the user input
   is a re-greeting / restate:
   - If all required slots (`region`, `check_in_date`,
     `check_out_date`, `party`) are present AND
     `slot_updates` is empty-or-trivial, emit
     `render_intent: {kind: "summarize"}` not
     `collect_missing`.
   - If `render_intent.kind == "collect_missing"`, the
     `missing` list MUST be non-empty.
8. As defense-in-depth, also patch `render_widget_chat`'s
   widget-selection logic in the same playbook (look for the
   step that maps `render_intent.kind` to a `widget_type`)
   to fall through to a `summarize`-style widget when
   `render_intent.kind == "collect_missing"` AND
   `missing == []` AND the captured slots are non-trivial.
9. Add a synthetic-input regression test for the playbook
   under `repos/travel/tests/` (or wherever existing playbook
   tests live).  Cover three cases:
   - empty slot state + "trip to paris" → expect
     `collect_missing` with non-empty `missing`.
   - full slot state + "trip to paris" → expect `summarize`
     and an `itinerary_summary` / `order_confirmation`
     widget, not `bot_text`.
   - full slot state + LLM returns broken
     `collect_missing,missing:[]` → render_widget_chat's
     defense-in-depth produces a `summarize` widget.

## Bug C — SPA Trip state panel misses `region` even when playbook captured it

### Symptom

Screenshot at 2026-05-27 ~20:05 UTC showed the SPA's right
sidebar Trip-state panel:

```
Region:      Missing
Dates:       2026-06-17 → 2026-06…
Party:       Missing
Star rating: Missing
Budget:      Missing
Bed type:    Missing
Amenities:   Missing
```

The corresponding execution's `final_slot_state` in noetl had:

```
region_label=Paris, region_city_code=PAR, region_country_code=FR,
region_kind=city, check_in_date=2026-06-17, ...
```

So the playbook captured region.  The SPA panel only picked up
`check_in_date` / `check_out_date` and missed everything else.

### Phase C — Bug C fix

10. Read `repos/travel/src/components/shell/ChatThread.tsx`
    and find:
    - The Trip-state side panel component (look for "Region:"
      / "Dates:" / "Party:" string literals or a `<TripStatePanel>`
      style import).
    - The `extractSlotState` function or whatever feeds
      `onSlotStateChange`.
11. Map the playbook's `final_slot_state` keys
    (`region_label`, `region_kind`, `region_city_code`,
    `region_country_code`, `party`, `nights`,
    `picked_flight_offer_id`, `booking_reference`, …) to the
    Trip-state panel fields.  The current implementation
    likely reads `slot_state.region` (an object) but the
    playbook produces `region_label` / `region_city_code` as
    flat scalars at the top level of `final_slot_state`.
12. Verify the mapping with a unit test under
    `repos/travel/src/components/shell/` (or wherever
    chat-thread tests live).  Cover:
    - region populated → Trip-state shows region label
    - dates populated → Trip-state shows date range
    - party populated → Trip-state shows party label
13. The Trip-state mapping fix is travel-SPA only.  It needs
    a Vite rebuild + redeploy (SPA build → static assets →
    served by the gateway or wherever the SPA is hosted).

## Phase D — open draft PRs

14. Three PRs, one per repo, all draft:
    - `noetl/gateway` — Bug A's new INFO log + (if a real
      transport bug is found) the actual fix.  If Bug A turns
      out to be a browser-side issue, just the INFO log lands
      so future repros are easier to triage.
    - `noetl/travel` — Bug B and Bug C in two commits on a
      single PR (LLM prompt + render_widget_chat defense +
      Trip-state slot mapping + tests).
    - No noetl/noetl PR expected for this round.
15. Cross-link to ai-meta
    `handoffs/active/2026-05-27-itinerary-planner-empty-widget/`
    in each PR body.

## Phase E — live re-deploy (GATED)

> ***Run only after explicit human go-ahead. Wait phrase:
> `proceed with playbook widget deploys`.***

16. After the PRs merge:
    - Rebuild gateway image (if Bug A's PR adds code beyond
      the diagnostic log, this is required; otherwise skip).
    - Rebuild travel SPA static bundle and deploy.  The
      travel SPA's deploy path lives in
      `repos/travel/automation/` or
      `repos/ops/automation/` — read it first; do NOT
      improvise.
    - No noetl rebuild expected.
17. Trigger one chat turn on `travel.mestumre.dev`.  Expected
    outcome:
    - SPA exits "Muno is planning…" reliably.
    - On a populated thread, SPA renders an
      `itinerary_summary` (or `order_confirmation`) widget,
      not `bot_text`.
    - Trip-state side panel shows the region label and any
      other populated slots.
18. Report log fingerprints in the result file.

## Hard rules

- Do NOT modify the cluster during Phases A–D.
- Do NOT push to `main` on any repo.
- Do NOT merge any PR yourself.
- Phase E is gated on the wait phrase
  `proceed with playbook widget deploys`.  If the user has
  not said it yet, write the result with
  `phase E blocked: awaiting "proceed with playbook widget deploys"`.
- No "canonical" in any prose or commit message.
- Per `agents/rules/logging.md` — no INFO on high-frequency
  poll paths.  Per-callback INFO at the synthetic-state-send
  branch is acceptable (bounded by playbook lifecycle).
- Do not store secrets in any file under ai-meta.
- If preconditions are missing, stop and report.

## What success looks like

- Bug A: a definitive answer to "why does the SPA sometimes
  not consume the synthetic playbook/state delivery", with
  grep-able fingerprints.  Either a real transport-layer bug
  fixed in noetl/gateway, OR a confirmed browser/tab issue
  with a SPA-side reconnect-and-replay mitigation.
- Bug B: every chat turn on a populated thread renders a
  domain widget (`itinerary_summary` / `order_confirmation`
  / `flight_list`), not `bot_text`.  An LLM-prompt unit test
  covers the regression.
- Bug C: Trip-state panel shows region, dates, party, etc.
  whenever the corresponding slot is set in
  `final_slot_state`.  A SPA unit test covers the mapping.

## FINAL REPORT

Always emit, even on early STOP.  Frontmatter:

```yaml
---
thread: 2026-05-27-itinerary-planner-empty-widget
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Body sections (one H2 per phase plus the standard
`Issues observed` and `Manual escalation needed`):

```markdown
## Phase A — Bug A read-only audit
- ...

## Phase B — Bug B fix
- ...

## Phase C — Bug C fix
- ...

## Phase D — open draft PRs
- ...

## Phase E — live re-deploy (GATED)
- phase E blocked: awaiting "proceed with playbook widget deploys"

## Issues observed
- ...

## Manual escalation needed
- ...
```
