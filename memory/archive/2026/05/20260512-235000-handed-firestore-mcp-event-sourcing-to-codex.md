# Handed Firestore MCP + event-sourcing tools + replay helper to Codex (trip-planner Round 3)

- date: 2026-05-12T23:50:00Z
- tags: trip-planner, adiona, muno, firestore, event-sourcing, replay, codex-handoff, round-3

## Round goal

Add `repos/ops/automation/agents/mcp/firestore.yaml` — a general-purpose
Firestore Native mode MCP playbook with CRUD plus event-sourcing
primitives (append-only events with transactional monotonic seq and
mandatory header redaction). Plus `ai-meta/scripts/firestore_replay.sh`
— an operator helper that walks event logs for offline inspection.

Round 3 of the trip-planner chat app (Adiona/muno) per the scoping doc
at `sync/issues/2026-05-12-trip-planner-app-scoping.md`. Builds the
storage substrate that Round 4 (LLM-driven itinerary agent) consumes.

## Pre-handoff (DONE, verified before handoff)

- Firestore API enabled on `noetl-demo-19700101`.
- Native mode database `(default)` in `us-central1`, region-locked,
  created 2026-05-12T23:19:20Z.
- Worker SA `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`
  has `roles/datastore.user` at project level.
- No new secret. Workload Identity auth.

## Architecture (key decisions)

- **MCP tools are GENERIC** — they CRUD whatever paths the caller
  passes. The trip-planner-specific `chat_threads/{threadId}/events`
  hierarchy is a CONVENTION the Round 4 agent follows. Keeps the
  playbook reusable.
- **`append_event` is transactional** — beginTransaction → query for
  max seq → assign max+1 → write → commit. Guarantees no two
  concurrent appends collide on seq.
- **Header redaction is mandatory** — `append_event` recursively
  redacts case-insensitive `authorization`, `x-goog-user-project`,
  `x-goog-api-key`, `x-figma-token`, `x-api-key`, cookies, and
  anything matching `(?i).*(token|secret|password|api[-_]?key|client[-_]?secret).*`.
  Replacement value is the literal string `<REDACTED>`. No bypass flag.
- **Workload Identity** auth via `google.auth.default(scopes=['datastore'])`
  → SA token from metadata server. Same pattern Google Places uses.
- **Hand-rolled Firestore-typed JSON** encoder/decoder inside the
  playbook. Do NOT introduce `google-cloud-firestore` as a new Python
  dep on the worker image in this round.
- **Replay tool (`firestore_replay.sh`)** uses the OPERATOR's local
  gcloud, NOT the worker SA — it's for offline debugging. Three modes
  (events / thread-list / doc). No agent-diff in this round; Round 4
  adds `replay --against-agent`.

## Scope locked

- 6 tools added in mcp/firestore.yaml.
- 1 ai-meta script: scripts/firestore_replay.sh.
- Brief tutorial 07 mention.
- All smoke writes scoped to `_smoke/round3-firestore-{nonce}` paths.
  Cleaned at end of phase 3. Production Firestore left EMPTY.

## Bridge artefacts

- `bridge/inbox/delegated/20260512-235000-firestore-mcp-event-sourcing.task.json`
- `scripts/firestore_mcp_event_sourcing_msg.txt`

## Trigger prompt for Codex (paste after pushing)

```
Add Firestore MCP playbook + event-sourcing tools + replay helper for
the trip-planner project (Adiona/muno). Round 3 of the planner.

Bridge task: bridge/inbox/delegated/20260512-235000-firestore-mcp-event-sourcing.task.json
Prompt details: scripts/firestore_mcp_event_sourcing_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260512-235000-firestore-mcp-event-sourcing.result.json

Pre-handoff (DONE): Firestore Native mode db `(default)` in us-central1,
worker SA has `roles/datastore.user`. Phase 1 re-verifies.

Run all 6 phases per the bridge task. Architectural rules:
  - WI auth only. No token secret.
  - MCP tools are GENERIC — no trip-planner data model baked in.
  - `append_event` is transactional (beginTransaction → max seq + 1).
  - Header redaction in append_event is MANDATORY. No bypass flag.
  - All smoke writes go to `_smoke/round3-firestore-{nonce}`. Smoke G
    deletes the entire test subtree. Production Firestore must be
    EMPTY of test data at end of phase 3.
  - Hand-roll Firestore JSON encoding inside the playbook — do NOT
    add `google-cloud-firestore` as a new Python dep on the worker
    image without separate approval.
  - tools/list returns exactly 6 entries.
  - No release cut. No git push from ai-meta.
  - Never log full doc data beyond ~200 chars per assertion.

If pre-handoff fails OR a smoke shows non-transactional seq behaviour
OR header redaction leaks: AMBER + STOP.
```

## What's after this — Round 4

Round 4 — LLM-driven itinerary agent. First deliverable is the formal
widget contract doc at `muno/playbooks/widget-contract/*.schema.json`
+ `muno/docs/architecture/widget-contract.md` (lives in muno per the
home-base rule, even though muno doesn't exist yet — Round 6 bootstraps
the repo and Round 4's PR seeds it OR the contract doc lands in ai-meta
temporarily and migrates when muno bootstraps; decide at the top of
Round 4). Then the agent itself: hybrid input (scripted widgets +
free-form chat), LLM extraction, dynamic playbook dispatch, full event
sourcing via this round's mcp/firestore.

Rounds 4 and 6 (muno bootstrap) can run in parallel once the widget
contract doc lands.

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `memory/inbox/2026/05/20260512-220000-handed-duffel-test-orders-to-codex.md`
- `memory/inbox/2026/05/20260512-230000-duffel-stays-unavailable-round-2.md`
- `repos/ops/automation/agents/mcp/google-places.yaml` (WI-auth playbook to mirror)
- https://firestore.googleapis.com/$discovery/rest?version=v1
- https://cloud.google.com/firestore/docs/reference/rest/v1/projects.databases.documents
