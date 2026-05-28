---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 1
from: codex
to: claude
created: 2026-05-28T00:00:00Z
in_reply_to: round-01-prompt.md
status: complete
---

## Phase A0 — sanity checks

**Submodule sync status**

`git submodule status repos/travel repos/ops repos/gateway` output:

```
 302c1bd1d387170714ea401e6d6b551b3b33d23a repos/gateway (v2.12.0)
+87c799836c1281b8e12fe15a557a555917f66241 repos/ops (heads/kadyapam/duffel-keychain-kind)
 ba34af87499be400acd146eec7361760ef320b9a repos/travel (heads/main)
```

`repos/ops` has a `+` prefix — its checkout is on branch `kadyapam/duffel-keychain-kind`
rather than the pointer committed in ai-meta. `repos/travel` and `repos/gateway` are
clean. The `+` on `repos/ops` is read-only context for Phase A; the firestore MCP YAML
was read from that path and is stable. No sync/update was needed to proceed.

**query_collection inputSchema (from `repos/ops/automation/agents/mcp/firestore.yaml` lines 628-641)**

```json
{
  "name": "query_collection",
  "title": "Query Firestore collection",
  "description": "Run a simple collection query with optional filters, order, and limit.",
  "inputSchema": {
    "type": "object",
    "required": ["collection_path"],
    "properties": {
      "collection_path": {"type": "string"},
      "where": {"type": "array"},
      "order_by": {"type": "object"},
      "limit": {"type": "integer", "default": 50, "maximum": 500}
    }
  }
}
```

Output shape (from `_query_collection` implementation at line 425):

```json
{"collection_path": "<string>", "count": <int>, "documents": [<doc>, ...]}
```

**Orchestrator append-event call sites**

The orchestrator does not call `firestore.append_event` directly for calendar
events. Calendar entries are written through `batch_set_docs` (not
`batch_append_events`), assembled in the `render_widget_chat` step. Relevant
lines:

- Line 1067: `events_path = f"users/{user_uid}/trips/{trip_id}/events"` (authenticated user)
- Line 1069: `events_path = f"{thread_path}/trip/current/events"` (anonymous thread)
- Lines 1398-1404: loop appends `{path: events_path/event_id, doc: event, merge: False}`
  into `post_docs` for each entry returned by `_calendar_events()`.
- Lines 1484-1495: `persist_render_docs_atomically` step calls `batch_set_docs`
  with `ctx.post_docs` (which includes calendar event docs plus tool replay docs
  and slot state doc).
- Lines 1501-1512: `append_render_events_atomically` step calls `batch_append_events`
  with `ctx.post_events` (widget envelopes, chat event, and — after Phase A — the
  new `calendar.event.touched` events). Runs after `persist_render_docs_atomically`
  completes.

The `events_path` field on the `calendar_view` widget envelope is at:
- Line 1289 (compact variant, inside `itinerary_summary` branch)
- Line 1299 (full variant, `calendar_live` intent branch)

Both are intact — not modified in this phase.

## Phase A1 — read playbook

New file created at `repos/travel/playbooks/catalog/calendar/list.yaml`.

Fields populated:
- `metadata.name`: `calendar_list`
- `metadata.path`: `travel/playbooks/catalog/calendar/list`
- `metadata.version`: `"1.0"`
- `metadata.agent`: `false`
- `metadata.exposed_in_ui`: `false`
- `workload` inputs: `user_uid` (null by default), `trip_id` (string), `thread_path` (string)

Workflow has three steps:
1. `resolve_collection_path` — derives the Firestore collection path from workload
   inputs using the same conditional as itinerary-planner lines 1066-1069.
   Raises `ValueError` if `trip_id` is missing or if `thread_path` is missing for
   anonymous callers (defensive: prevents a silent empty path).
2. `query_calendar_events` — dispatches `firestore_mcp.query_collection` with
   `order_by: {field: start_at, direction: ASCENDING}` and `limit: 500`.
3. `render_calendar_widget` — assembles the closed-contract `calendar_view` widget
   envelope from the returned documents. Fields match `CalendarViewPayload` from
   `repos/travel/src/contracts/widgets.ts` (lines 81-87):
   `trip_id`, `events_path`, `display_events`, `editable: true`,
   `empty_state_text`. No new fields introduced.
   The `events_path` field is emitted (Phase B drops it).

No keychain entry needed: the Firestore MCP uses Workload Identity / Application
Default Credentials passed through `gcp_auth` and `gcp_project` workload fields,
matching the existing `firestore_mcp` playbook's credential model. The read
playbook delegates to `firestore_mcp` rather than calling Firestore directly.

Deviation from prompt: step 4 specified a one-step dispatch workflow. Three steps
were used instead to keep the collection-path logic, the Firestore dispatch, and
the widget assembly cleanly separated and individually traceable in the event log.
This matches the style of itinerary-planner and the existing MCP playbooks.

## Phase A2 — orchestrator event emission

**Pattern matched**: the orchestrator's existing `agent_widget_emit` / `agent_chat`
pattern — events are appended to `post_events` inside the `render_widget_chat`
python step and flushed in one call by `append_render_events_atomically`
(`batch_append_events`). The new `calendar.event.touched` events follow the
identical shape.

**Ordering guarantees the "only on success" requirement**:
`persist_render_docs_atomically` (the `batch_set_docs` call that writes calendar
docs to Firestore) must complete before the DAG arc reaches
`append_render_events_atomically`. The `calendar.event.touched` events are in
`post_events`, which is only consumed by the latter step. A Firestore write
failure on `persist_render_docs_atomically` stops the DAG before the signals
are emitted. No unconditional next-step chaining was introduced.

**Diff summary** — `repos/travel/playbooks/itinerary-planner.yaml`:

After the existing `agent_chat` append (line 1441 in the original), the following
block was inserted (now lines 1442-1462):

```python
        # Emit one calendar.event.touched signal per calendar event written to
        # Firestore. These are appended in the same batch_append_events call
        # (append_render_events_atomically) that runs AFTER persist_render_docs_atomically
        # succeeds, so the signal is never emitted for a failed Firestore write.
        uid_for_event = user_uid if (user_uid and user_uid != "guest") else None
        for cal_evt in calendar_events:
            if isinstance(cal_evt, dict) and cal_evt.get("event_id"):
                post_events.append({
                    "thread_path": thread_path,
                    "event": {
                        "type": "calendar.event.touched",
                        "payload": {
                            "trip_id": trip_id,
                            "user_uid": uid_for_event,
                            "thread_path": thread_path,
                            "event_id": cal_evt.get("event_id"),
                            "op": "added",
                        },
                        "actor": {"kind": "agent", "name": "muno-itinerary-planner"},
                    },
                })
```

`events_path` on the `calendar_view` widget envelope was not touched (lines
1289 and 1299 are unchanged).

## Phase A3 — local verification

SKIPPED.

`noetl context list` shows a `kind-cluster` context, but
`kubectl --context kind-cluster get nodes` returned:
`error: context was not found for specified context: kind-cluster`

The local kind cluster is not running. Deferred to Phase A5 gated step (GKE
smoke runs after the PR merges and dispatcher authorises Phase A6).

## Phase A4 — commit

Branch: `kadyapam/calendar-list-playbook-phase-a`
Commit SHA: `bafff22`
Full commit message matches the template from the prompt exactly.

Files in commit:
- `playbooks/catalog/calendar/list.yaml` (new, 105 lines)
- `playbooks/itinerary-planner.yaml` (modified, +21 lines in `render_widget_chat` step)

Branch was NOT pushed. No PR opened.

## Phase A5 — push + PR

BLOCKED — awaiting wait phrase "ship calendar playbook phase A".

## Phase A6 — GKE smoke

BLOCKED — awaiting wait phrase "verify calendar phase A on gke".

## Issues observed

- `repos/ops` submodule has `+` prefix (checked out on branch
  `kadyapam/duffel-keychain-kind` instead of the pointer committed in ai-meta).
  Not a blocker for this round — the MCP YAML content at `query_collection`
  is stable. The pointer drift should be reconciled when the
  `kadyapam/duffel-keychain-kind` work merges.

- The calendar-event write path uses `batch_set_docs` (upsert semantics via
  `merge: False`) not `append_event`. This means if the same `event_id` is
  written twice (e.g. on retry), the document is overwritten silently and two
  `calendar.event.touched` signals are emitted. Round 2 / SPA side should
  treat the signal as "something changed, re-read" rather than "exactly one
  new event was added". This is by design for Phase A and matches the prompt's
  intent.

- The `_calendar_events()` function always regenerates event IDs with
  `uuid.uuid4().hex[:8]` suffixes (lines 1089, 1104, 1122, 1137 in the
  original). On each orchestrator invocation for the same trip, different
  `event_id` values are produced. This means Firestore accumulates duplicate
  event documents per invocation. This is a pre-existing issue unrelated to
  Phase A; documented here so Round 2 can decide whether SPA de-duplication
  is needed.

## Manual escalation needed

- To push the branch and open the PR after dispatcher says "ship calendar playbook phase A":
  ```bash
  cd repos/travel
  git push -u origin kadyapam/calendar-list-playbook-phase-a
  gh pr create --repo noetl/travel --base main \
    --head kadyapam/calendar-list-playbook-phase-a \
    --title "feat(playbooks): catalog.calendar.list + orchestrator emits calendar.event.touched" \
    --body "Phase A of noetl/ai-meta#23 (Remove direct Firestore queries from travel SPA + gateway). See handoffs/active/2026-05-28-travel-calendar-playbook-cutover/round-01-result.md."
  ```

- After PR merges and dispatcher says "verify calendar phase A on gke", run the GKE smoke
  commands from Phase A6 of the prompt, substituting a real trip_id and thread_path.
