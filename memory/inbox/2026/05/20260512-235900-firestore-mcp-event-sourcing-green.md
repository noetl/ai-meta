# Firestore MCP event-sourcing GREEN

Round `20260512-235000-firestore-mcp-event-sourcing` closed GREEN.

What landed:

- `repos/ops/automation/agents/mcp/firestore.yaml` via ops#86.
- Generic MCP surface with exactly six tools: `set_doc`, `get_doc`,
  `query_collection`, `delete_doc`, `append_event`, and
  `replay_events`.
- Firestore auth uses the worker service account through Workload
  Identity / ADC with datastore scope. No token secret or service
  account key was added.
- Firestore REST JSON encoding/decoding is hand-rolled inside the
  playbook; no `google-cloud-firestore` worker dependency was added.
- `append_event` uses Firestore transactions:
  `beginTransaction -> runQuery max seq -> commit`, and redacts
  sensitive headers before writing the event payload.
- `scripts/firestore_replay.sh` in ai-meta reads event streams and docs
  with operator-local `gcloud auth print-access-token`.
- `CLAUDE.md` now advertises the replay helper under quick commands.
- Tutorial 07 gained a short "Event-sourced storage (Round 3)" section
  via docs#66.

Validation:

- Firestore API enabled on project `noetl-demo-19700101`.
- Firestore Native `(default)` database exists in `us-central1`.
- Worker service account
  `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com` has
  `roles/datastore.user`.
- Worker pod ADC probe reached
  `projects/noetl-demo-19700101/databases/(default)`.
- GKE registered Firestore MCP v6, catalog id
  `625474366091821164`.
- Post-merge tools/list execution `625474433754333293` returned exactly
  six tools.
- Smoke root `_smoke/round3-firestore-1778629315` passed:
  set/get deep equality, collection query ordering `[5, 3]`,
  transactional seq `[1, 2, 3, 4, 5]`, mandatory header redaction,
  type-filter replay, replay helper output, and cleanup.
- `_smoke` collection was verified empty afterward. Partial fixtures
  from earlier failed runs were also deleted.

Fix-forward during the round:

- The first tools/call run hit the known NoETL Python `globals/locals`
  behavior. The playbook now republishes helper functions and module
  bindings through `globals().update(...)`.
- The first append_event run used the database root for Firestore
  transaction endpoints. The correct REST endpoints are under
  `/documents:beginTransaction` and `/documents:commit`.

Why it matters:

Round 3 gives the trip-planner project a generic event-sourced storage
primitive without baking in the trip data model. Round 4 can now persist
chat turns, widget submissions, tool calls, and itinerary projections
under caller-chosen Firestore paths, then replay those streams later for
agent diffing and audit.
