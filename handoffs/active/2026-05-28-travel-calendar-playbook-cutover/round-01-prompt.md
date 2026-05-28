---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 1
from: claude
to: codex
created: 2026-05-28T07:25:00Z
status: open
expects_result_at: round-01-result.md
tracks: noetl/ai-meta#23
wait_phrase: "ship calendar playbook phase A"
---

# Phase A: catalog.calendar.list playbook + orchestrator emits calendar.event.touched

> **Tracks:** [noetl/ai-meta#23](https://github.com/noetl/ai-meta/issues/23) — Remove direct
> Firestore queries from travel SPA + gateway (playbook-only data access).
>
> This round only does Phase A of the four-phase plan on #23. Phases B
> (SPA refactor), C (gateway code removal), and D (wiki + docs) are
> follow-up rounds gated on this one shipping cleanly.

The travel SPA's calendar widget today live-updates by having the
**gateway** subscribe to a Firestore collection on the SPA's behalf
(`POST /api/subscriptions/firestore`). That violates the
gateway-is-gatekeeper-only rule in
`agents/rules/execution-model.md`. The fix is to route reads
through a playbook executed by a worker, and to use the NoETL
event stream (which the gateway already multicasts) as the
"something changed, re-read it" signal.

Phase A introduces the two ingredients on the **noetl/travel** side
that make this cutover possible. **Nothing on the SPA or gateway
changes in this round.** When Phase A lands and is verified end-to-
end against GKE, Round 2 will cut the SPA over and Round 3 will
delete the gateway-side Firestore subsystem.

## Background

### Current calendar data path (the thing being replaced)

- Orchestrator playbook: `repos/travel/playbooks/itinerary-planner.yaml`
  (1573 lines).
  - Writes calendar events to Firestore via `mcp/firestore.append_event`
    at `users/{user_uid}/trips/{trip_id}/events` (or
    `{thread_path}/trip/current/events` for anonymous threads) —
    derived around line 1067.
  - Emits a `calendar_view` widget envelope back to the SPA with
    `events_path` set to the same collection path (line ~1289 for
    `kind: calendar_live`, line ~1305 for the `calendar_live` intent).
- SPA: `repos/travel/src/components/widgets/CalendarView.tsx:89` →
  `subscribeToCalendarEvents(data.events_path, ...)` from
  `src/api/gatewaySubscriptions.ts` →
  `POST /api/subscriptions/firestore` with
  `{path: events_path, scope: 'owner'}`.
- Gateway: `repos/gateway/src/firestore_subscriptions.rs`
  (412 lines) spawns a Python listener
  (`repos/gateway/scripts/firestore_listener.py`) that subscribes to
  the Firestore collection and forwards each change event over the
  NoETL SSE stream as a `subscription/event` message with
  `params: {subscription_id, doc_id, data, op}`.

### Replacement shape (option d from #23 comment)

- **Read playbook**: `catalog://travel/playbooks/catalog/calendar/list`
  reads the same Firestore collection (using the Firestore MCP tool
  `query_collection`, which already exists — see
  `repos/ops/automation/agents/mcp/firestore.yaml` around line 417,
  function `_query_collection`). Returns the full event list as a
  rendered `calendar_view` widget envelope.
- **Change signal**: orchestrator emits a `calendar.event.touched`
  event to the NoETL event log every time it appends or modifies a
  calendar entry. SPA (in a later round) subscribes to the NoETL
  `/events` SSE stream, filters by `trip_id`, and re-runs the read
  playbook whenever a `calendar.event.touched` event arrives for
  its trip.

### Where to operate

- `repos/travel/playbooks/catalog/calendar/list.yaml` — **new file**
  (you create it).
- `repos/travel/playbooks/itinerary-planner.yaml` — **edit in place**
  (add the event emission alongside the existing
  `mcp/firestore.append_event` calls; do NOT change the existing
  write path or remove `events_path` from the widget — Phase B
  drops `events_path` once the SPA stops using it).
- `repos/ops/automation/agents/mcp/firestore.yaml` — **read only** in
  this round. Confirm the `query_collection` shape, do not modify.

### Branch + repo state

- Operate from `repos/travel` `main` HEAD. Latest pointer in
  `ai-meta` already tracks the muno orchestrator with the
  widget-payload carve-out (noetl/noetl#622 + travel commits
  through 2026-05-27).
- Create branch `kadyapam/calendar-list-playbook-phase-a` for
  the work.

## Phases

### Phase A0 — sanity checks (no remote writes)

1. Confirm submodule sync: `git submodule status repos/travel
   repos/ops repos/gateway` shows no `+` / `-` prefix in front of
   the SHAs. If it does, run
   `git submodule sync --recursive && git submodule update --init --recursive`
   from the ai-meta root and re-check.
2. Confirm `repos/ops/automation/agents/mcp/firestore.yaml` exposes
   `query_collection` with `(collection_path, …) → {documents,
   count}` shape. Grep for `query_collection` in the YAML to find
   the actual `inputSchema` and `output` shape; capture them in the
   final report so Round 2 can match the contract exactly.
3. Confirm the orchestrator's existing append-event call sites by
   greping `repos/travel/playbooks/itinerary-planner.yaml` for
   `firestore.append_event` and `events_path`. Record line numbers
   and the data being passed in the final report — Round 2's SPA
   refactor will reference these.

### Phase A1 — design the read playbook

> Pure design / file-write phase. No remote calls. Unattended.

4. Write `repos/travel/playbooks/catalog/calendar/list.yaml` so that:
   - **`metadata.name`**: `calendar_list`.
   - **`metadata.path`**: `travel/playbooks/catalog/calendar/list`.
   - **`metadata.version`**: `1.0`.
   - **`metadata.agent`**: `false` (not exposed as an MCP).
   - **`metadata.exposed_in_ui`**: `false`.
   - **`workload`** inputs:
     - `user_uid: string | null` — anonymous threads pass `null`.
     - `trip_id: string`.
     - `thread_path: string` — used for the anonymous-thread path.
   - **`workflow`** has one Firestore dispatch step that calls the
     `firestore_mcp` agent's `query_collection` tool with the
     correct collection path derived from the workload (mirror the
     existing orchestrator logic at line ~1067):
     - `users/{user_uid}/trips/{trip_id}/events` when `user_uid` is
       non-null.
     - `{thread_path}/trip/current/events` otherwise.
   - **Output**: render a `calendar_view` widget envelope with
     `display_events` populated from the Firestore documents,
     `events_path` still emitted (Phase B drops it), and
     `editable: true`. Match the shape currently emitted around
     orchestrator line 1287.
5. Cross-reference: the widget envelope schema lives at
   `repos/travel/src/contracts/widgets.ts` →
   `CalendarViewPayload`. The fields the playbook must populate are
   `trip_id`, `events_path`, `display_events`, `editable`,
   `empty_state_text`. Don't invent new fields.
6. Match the keychain convention from the existing playbooks: the
   Firestore MCP resolves its own credentials via the keychain. The
   read playbook delegates to `firestore_mcp` rather than calling
   Firestore directly — workers, not playbooks, hold business-logic
   secrets.

### Phase A2 — orchestrator emits calendar.event.touched

> Pure edit phase. No remote calls. Unattended.

7. In `repos/travel/playbooks/itinerary-planner.yaml`, for every
   step that writes a calendar event (i.e. every dispatch that
   targets `firestore_mcp.append_event` with a calendar payload),
   add a follow-on step that emits a `calendar.event.touched`
   event to the NoETL event log. The event payload must carry:
   - `trip_id` (string)
   - `user_uid` (string | null)
   - `thread_path` (string)
   - `event_id` (string — the id Firestore assigned, if available;
     otherwise the orchestrator's local id)
   - `op` — one of `added`, `modified`, `removed`.
8. The emission must happen **after** the Firestore write succeeds
   (so a failed write does not produce a phantom change signal).
   Use a `result.success`-conditional step or whatever the
   noetl/v2 DSL idiom is for "only if previous step succeeded" — do
   NOT use unconditional next-step chaining.
9. Identify the NoETL event-emit step kind that's idiomatic for
   this. Likely candidates: a `tool: { kind: event_emit }` step, or
   the existing pattern the orchestrator uses for `widget` events.
   Pick whichever matches the orchestrator's existing
   non-Firestore event-emission style — do not introduce a new
   kind.
10. Do **not** remove the existing `events_path` field from the
    `calendar_view` widget envelope (orchestrator lines ~1289 and
    ~1299–1305). Phase B in Round 2 drops it; Phase A keeps the SPA
    working unchanged.

### Phase A3 — local verification (no remote writes)

> Unattended. Local-only smoke. Skip if local kind isn't running.

11. If a local kind cluster + Firestore emulator are available
    (check `noetl context list`), run:
    ```bash
    noetl --context kind-cluster register playbook \
      repos/travel/playbooks/catalog/calendar/list.yaml
    noetl --context kind-cluster register playbook \
      repos/travel/playbooks/itinerary-planner.yaml
    noetl --context kind-cluster exec \
      catalog://travel/playbooks/catalog/calendar/list \
      --runtime distributed \
      --payload '{"trip_id":"smoke-test","user_uid":null,"thread_path":"threads/smoke"}' \
      --json
    ```
    Confirm execution completes (status `COMPLETED`, `failed:
    false`) and the response carries a `calendar_view` widget
    envelope with `display_events` (possibly empty for a smoke
    trip).
12. If only GKE is reachable, **skip Phase A3 in this round** and
    note "deferred to Phase A4 gated step" in the result. GKE
    smoke-test is gated below — don't run it without explicit
    go-ahead.

### Phase A4 — commit the noetl/travel changes

> Unattended (commits to a feature branch — not main, not push).

13. From `repos/travel`:
    ```bash
    git checkout -b kadyapam/calendar-list-playbook-phase-a
    git add playbooks/catalog/calendar/list.yaml \
            playbooks/itinerary-planner.yaml
    git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
    feat(playbooks): catalog.calendar.list + orchestrator emits calendar.event.touched

    Phase A of the four-phase Firestore removal tracked in
    noetl/ai-meta#23.  Adds:

    - playbooks/catalog/calendar/list.yaml — read playbook that
      returns the calendar_view widget envelope for a given
      (user_uid, trip_id) by dispatching firestore_mcp.query_collection.
    - playbooks/itinerary-planner.yaml — emits a
      calendar.event.touched NoETL event after every successful
      Firestore calendar-event append, so future SPA / subscribers
      can re-read on signal without the gateway-direct subscription.

    Phase A does NOT touch the SPA or the gateway; the existing
    /api/subscriptions/firestore path keeps working unchanged.
    Phase B (SPA cutover) and Phase C (gateway removal) follow in
    later rounds of the handoff thread.

    Refs noetl/ai-meta#23
    EOF
    )"
    ```
14. Do **NOT** push the branch. Do **NOT** open a PR. Round 1 ends
    with the branch committed locally so the dispatcher can review
    the diff before authorising the push.

### Phase A5 — push + open PR

> ***Run only after explicit human go-ahead. Wait phrase: `ship calendar playbook phase A`.***

15. `cd repos/travel && git push -u origin kadyapam/calendar-list-playbook-phase-a`
16. Open the PR with `gh pr create --repo noetl/travel --base main
    --head kadyapam/calendar-list-playbook-phase-a` and a body that
    cites `noetl/ai-meta#23` and the handoff thread path.
17. Do NOT merge. Return the PR URL in the result.

### Phase A6 — GKE smoke

> ***Run only after explicit human go-ahead. Wait phrase: `verify calendar phase A on gke`.***

18. After the PR merges and the catalog is re-registered against
    GKE (the dispatcher handles the register), run:
    ```bash
    noetl --context gke-prod exec \
      catalog://travel/playbooks/catalog/calendar/list \
      --runtime distributed \
      --payload '{"trip_id":"<real-trip-id>","user_uid":null,
                  "thread_path":"<real-thread-path>"}' \
      --json
    ```
19. Fetch the events for the resulting execution and confirm:
    - `command.completed` for the Firestore query step shows
      `isError: false` and a non-zero document count.
    - The final playbook response carries a `calendar_view` widget
      envelope.
20. Drive a chat turn that appends a calendar event (e.g. confirm a
    flight selection in the SPA), then fetch events for the
    orchestrator execution. Confirm a `calendar.event.touched`
    event appears with the right `trip_id` and `op`.

## FINAL REPORT

Write `round-01-result.md` with frontmatter:

```yaml
---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Body sections — one H2 per phase, plus the two standard sections:

```markdown
## Phase A0 — sanity checks
- query_collection inputSchema captured
- orchestrator append-event call sites listed with line numbers

## Phase A1 — read playbook
- diff against ../before (or `git show` if committed)
- any deviation from the prompt's field list, with rationale

## Phase A2 — orchestrator event emission
- which existing event-emit pattern was matched
- file:line diff summary for the new emit steps

## Phase A3 — local verification
- COMPLETED / SKIPPED + reason
- execution_id + key event-log lines if run

## Phase A4 — commit
- branch name + commit SHA

## Phase A5 — push + PR
- COMPLETED / BLOCKED-awaiting-wait-phrase
- PR URL if completed

## Phase A6 — GKE smoke
- COMPLETED / BLOCKED-awaiting-wait-phrase
- execution_id + calendar.event.touched signal confirmation if completed

## Issues observed
- bullet list of anything surprising. Include grep-able
  fingerprints (error strings, status codes, stack frame top lines).
  Do NOT paraphrase.

## Manual escalation needed
- everything you could not complete unattended, with the precise
  command(s) a human should run.
```

## Hard rules for this thread

- Never push to `origin/main` on any repo unless this prompt
  explicitly says so. Phase A5 + A6 are explicitly gated.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`,
  especially `execution-model.md`, `issue-tracking.md`, and
  `wiki-maintenance.md` (the wiki updates in Phase D / Round 2
  are tracked by Rule 1+2 — don't pre-empt them here).
- Do not store secrets in any file under ai-meta (the repo is
  public).
- If a step's preconditions aren't met, stop and report — don't
  improvise around blockers.
- Do not modify `repos/gateway/` in this round.
- Do not modify `repos/travel/src/` (SPA) in this round.
- Do not delete `events_path` from the orchestrator's widget
  envelope in this round — that belongs in Phase B.
