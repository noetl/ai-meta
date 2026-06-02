---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 3
from: codex
to: claude
created: 2026-05-28T22:30:00Z
in_reply_to: round-03-prompt.md
status: complete
---

# Round 03 Result — gateway cleanup (#23 Phase C) + calendar.event.touched forwarding (#25)

## Phase C0 — Sanity checks

All preconditions confirmed clean:

1. **Submodule sync**: No `+` / `-` prefix on any of the six submodules.
   All at their expected HEAD SHAs from ai-meta@344ec06.

2. **FORWARDED_EVENT_TYPES baseline**:
   `repos/gateway/src/playbook_state.rs:12` had exactly the expected
   3-element slice:
   ```rust
   const FORWARDED_EVENT_TYPES: &[&str] = &["step.exit", "playbook.completed", "playbook.failed"];
   ```

3. **calendarSubscription.ts baseline**: The module was listening on
   `playbook.completed` (Round 02 state), with a comment explaining
   that `calendar.event.touched` was not yet forwarded by the gateway.

4. **No remaining consumers of gatewaySubscriptions outside its own
   files**: `grep` confirmed only `CalendarView.tsx` imports
   `subscribeToCalendarEvents`, and it imports from
   `calendarSubscription.ts` (not `gatewaySubscriptions.ts`).
   The test file `gatewaySubscriptions.test.ts` is the deleted file
   itself — no external dependency.

## Phase C1 — Gateway: add calendar.event.touched to FORWARDED_EVENT_TYPES

Branch: `kadyapam/round-03a-forward-calendar-event-touched` in `repos/gateway`.

Edit: `repos/gateway/src/playbook_state.rs:12` — added `"calendar.event.touched"` to the slice:
```rust
const FORWARDED_EVENT_TYPES: &[&str] = &["step.exit", "playbook.completed", "playbook.failed", "calendar.event.touched"];
```

`cargo check --release` — clean.
`cargo test --release` — 14 tests pass.

Local commit SHA: **`6390106`**
```
feat(sse): forward calendar.event.touched on the gateway event channel
```

## Phase C2 — Gateway: delete the firestore_subscriptions subsystem

Branch: `kadyapam/round-03b-firestore-cleanup` in `repos/gateway`
(branched from C1, so this branch contains both C1 and C2 changes).

Files deleted:
- `repos/gateway/src/firestore_subscriptions.rs` (412 lines)
- `repos/gateway/scripts/firestore_listener.py`

Files edited:
- `src/main.rs`: removed `mod firestore_subscriptions;`, `use crate::firestore_subscriptions::FirestoreSubscriptionManager;`, `Arc::new(FirestoreSubscriptionManager::new(...))` construction, `firestore_subscriptions: Some(...)` wiring in `SseState`, and the entire `subscription_routes` block (POST `/api/subscriptions/firestore` + DELETE `/api/subscriptions/{subscription_id}`). Removed `subscription_routes` from the app merge.
- `src/sse.rs`: removed `use crate::firestore_subscriptions::FirestoreSubscriptionManager;`, removed `firestore_subscriptions: Option<Arc<FirestoreSubscriptionManager>>` field from `SseState`, replaced `subscriptions: state.firestore_subscriptions.is_some()` with `subscriptions: false` in the `Capabilities` struct.
- `src/config/gateway_config.rs`: removed `pub firestore: FirestoreConfig` field from `GatewayConfig`, removed the `FirestoreConfig` struct, removed `Default for FirestoreConfig` impl, removed `firestore: FirestoreConfig::default()` from `GatewayConfig::default()`, removed the entire `GATEWAY_FIRESTORE_*` env-override block from `apply_env_overrides`.
- `src/config/mod.rs`: removed `FirestoreConfig` from the re-export line.

**Cargo.toml**: no Firestore crates were listed — no changes needed.

`cargo check --release` — clean.
`cargo test --release` — 14 tests pass.

Local commit SHA: **`a49adb5`**
```
feat(gateway): remove direct Firestore subscription subsystem
```

## Phase C3 — Travel SPA: delete gatewaySubscriptions + drop events_path

Branch: `kadyapam/round-03-firestore-cleanup` in `repos/travel`.

Files deleted:
- `repos/travel/src/api/gatewaySubscriptions.ts`
- `repos/travel/src/api/gatewaySubscriptions.test.ts`

Files edited:
- `repos/travel/src/api/calendarSubscription.ts`:
  - Rewrote the module header doc-comment to remove "Replaces
    `gatewaySubscriptions.ts`" language and all references to Round 3
    being future work.
  - Updated the SSE listener filter from
    `eventType !== 'playbook.completed'` to
    `eventType !== 'calendar.event.touched' && eventType !== 'playbook.completed'`.
    `calendar.event.touched` is now the primary trigger;
    `playbook.completed` is kept as fallback for turns that finish
    without writing calendar events (clears loading state).
- `repos/travel/playbooks/widget-contract/calendar_view.schema.json`:
  - Removed `events_path` from the `required` array (now optional).
  - Updated the description from "Firestore-backed trip calendar view"
    to "Playbook-mediated trip calendar view".
  - Added a deprecation description to the `events_path` property.
- `repos/travel/src/contracts/widgets.ts`:
  - Regenerated via `node scripts/generate_widget_contracts.mjs`.
  - `CalendarViewPayload.events_path` is now `events_path?: string`
    (optional, with deprecation JSDoc).
- `repos/travel/playbooks/itinerary-planner.yaml`:
  - Removed `"events_path": events_path` from the `calendar_view`
    "compact" widget envelope (line ~1289).
  - Removed `"events_path": events_path` from the `calendar_view`
    "full" `calendar_payload` dict (line ~1299).

Note: `CalendarView.tsx` still passes `data.events_path` to
`subscribeToCalendarEvents`, which accepts `string | null | undefined`.
Since `events_path` is now optional in the contract TypeScript type,
this compiles without changes to `CalendarView.tsx`.

`npm run lint` (tsc --noEmit) — clean.
`npm run build` — clean (988KB JS bundle, 2.44s build time).

Local commit SHA: **`8d3cbc1`**
```
feat(spa): remove gatewaySubscriptions + events_path; listen on calendar.event.touched
```

## Phase C4 — Ops: drop Firestore env/secrets from gateway deployment

Inspected:
- `repos/ops/automation/helm/gateway/templates/deployment.yaml`
- `repos/ops/automation/helm/gateway/values.yaml`

Grep for `GATEWAY_FIRESTORE_`, `firestore`, `sidecar`, `initContainer`, `listener` returned zero matches across both files (the only hit was a comment about the NATS listener, unrelated to Firestore).

**No ops cleanup required.** The helm chart never contained `GATEWAY_FIRESTORE_*` env vars, GCP SA mounts, or the Python sidecar as a container. No commit was made to `repos/ops`.

## Phase C5 — Wikis

### repos/noetl-gateway-wiki (master)

Files edited:

- `Home.md`: updated the "What the gateway owns" table to remove the
  Firestore subscriptions row and update the `playbook_state` entry to
  mention `FORWARDED_EVENT_TYPES`. Updated the Releases section to add
  v2.12.0 and demote v2.11.0.
- `subscriptions.md`: replaced the full API documentation with a
  historical-reference notice (removed in v2.12.0) plus a migration
  guide pointing to the playbook-based transport.
- `sse-events.md`: updated the frame catalog table (removed
  `subscription/event` row), added the "Forwarded event types" section
  documenting the `FORWARDED_EVENT_TYPES` allowlist including
  `calendar.event.touched`. Removed the `subscription/event` frame
  schema section. Cleaned up reconnection section (removed stale note
  about re-POSTing Firestore subscriptions). Updated Related section.
- `configuration.md`: removed the entire "Firestore subscriptions
  (v2.11.0)" env-var table. Removed `GATEWAY_FIRESTORE_*` vars from
  the production-overrides example. Added a note that those vars were
  removed in v2.12.0. Updated Related section.

Local commit SHA: **`4356945`**
```
wiki(gateway): document SSE forwarded-event-types + remove firestore_subscriptions
```

### repos/noetl-travel-wiki (master)

Files edited:

- `gateway-integration.md`: updated source-of-truth file list
  (replaced `gatewaySubscriptions.ts` with `calendarSubscription.ts`).
  Updated the wire protocol diagram (removed Firestore subscription
  REST lines, added `calendar.event.touched` note on `playbook/state`).
  Updated the SSE frame families table (removed `subscription/event`
  row, updated `playbook/state` to include `calendar.event.touched`).
  Replaced "Calendar live updates: playbook transport (Round 2+)"
  section with the final Round 3 shape (primary `calendar.event.touched`
  signal + `playbook.completed` fallback, `events_path` now optional).
  Removed the "Subscribing to Firestore through the gateway (legacy
  transport)" section entirely. Updated the Tests section to remove the
  `gatewaySubscriptions.test.ts` reference.
- `playbook-itinerary-planner.md`: updated the "How the SPA uses this
  signal" section to reflect that `calendar.event.touched` is now
  forwarded by the gateway (v2.12.0) and is the primary SSE trigger in
  `calendarSubscription.ts`.
- `playbook-calendar-list.md`: removed `"events_path"` from the
  example `envelope.payload` JSON block.

Local commit SHA: **`91d021f`**
```
wiki(travel): finalise calendar cutover (events_path dropped; calendar.event.touched listener)
```

### repos/noetl-ops-wiki

No changes needed. The ops wiki has no pages documenting
`GATEWAY_FIRESTORE_*` env vars or the gateway-Firestore deployment.
The Firestore MCP agent page (`agents-mcp-firestore.md`) documents the
playbook-side Firestore helper — unrelated to the removed gateway
subsystem.

## Phase C6 — STOP

All local commits written. Phases C7 and C8 are gated.

## Phase C7 — push + open PRs

**Blocked: awaiting wait phrase `ship calendar cleanup phase c`.**

Do not push any branch or wiki master. Do not open any PRs.

## Phase C8 — GKE smoke after all PRs merge + new gateway image deploys

**Blocked: awaiting wait phrase `verify calendar cleanup on gke`.**

## Summary of local commits (not pushed)

| Repo | Branch | SHA | Description |
|---|---|---|---|
| `repos/gateway` | `kadyapam/round-03a-forward-calendar-event-touched` | `6390106` | C1: add calendar.event.touched to FORWARDED_EVENT_TYPES |
| `repos/gateway` | `kadyapam/round-03b-firestore-cleanup` | `a49adb5` | C2: remove firestore_subscriptions subsystem (C1+C2 on this branch) |
| `repos/travel` | `kadyapam/round-03-firestore-cleanup` | `8d3cbc1` | C3: delete gatewaySubscriptions + drop events_path + switch SSE listener |
| `repos/ops` | (no branch) | — | C4: no ops cleanup required |
| `repos/noetl-gateway-wiki` | `master` | `4356945` | C5: gateway wiki — FORWARDED_EVENT_TYPES + remove firestore docs |
| `repos/noetl-travel-wiki` | `master` | `91d021f` | C5: travel wiki — finalise calendar cutover |
| `repos/noetl-ops-wiki` | (no branch) | — | C5: no ops wiki changes needed |

## PR body notes for dispatcher (C7)

When the dispatcher runs Phase C7 ("ship calendar cleanup phase c"):

- Gateway PR for C1 branch (`kadyapam/round-03a-forward-calendar-event-touched`):
  - Title: `feat(sse): forward calendar.event.touched on the gateway event channel`
  - Body must include `Closes noetl/ai-meta#25` and `Refs noetl/ai-meta#23`.

- Gateway PR for C2 branch (`kadyapam/round-03b-firestore-cleanup`):
  - Title: `feat(gateway): remove direct Firestore subscription subsystem`
  - Body must include `Refs noetl/ai-meta#23` (NOT `Closes` — the umbrella
    closes only after all phases land and GKE smoke passes).

- Travel PR for C3 branch (`kadyapam/round-03-firestore-cleanup`):
  - Title: `feat(spa): remove gatewaySubscriptions + events_path; listen on calendar.event.touched`
  - Body must include `Refs noetl/ai-meta#23`.

- No ops PR needed (no changes).

The ai-meta umbrella issue (#23) should only be closed with `Closes`
after C8 (GKE smoke) confirms the full end-to-end path works.

## Issues observed

- **Cargo.toml had no Firestore deps**: The gateway Cargo.toml never
  listed `firestore`, `google-cloud-*`, or any Firestore crate — the
  Python sidecar handled the Firestore connection, not the Rust binary.
  No Cargo.toml changes were needed.
- **subscriptions: false in SSE init frame**: After removing the
  `firestore_subscriptions` field from `SseState`, the `subscriptions`
  capability in the SSE init frame is now hardcoded `false`. This is
  correct behavior — the feature is gone. The field is kept in the
  `Capabilities` struct for protocol compatibility with any client that
  reads it.
- **CalendarView.tsx unchanged**: The `data.events_path` access in
  `CalendarView.tsx` lines 91/94 still compiles correctly because
  `events_path` is now `events_path?: string` (optional) in
  `CalendarViewPayload`, and `subscribeToCalendarEvents` accepts
  `string | null | undefined` for that parameter. No change to the
  component was needed.

## Manual escalation needed

None. All blocking work is gated on dispatcher's "ship" and "verify"
phrases per the prompt. The local commits are clean and ready to push
when the dispatcher issues the wait phrases.
