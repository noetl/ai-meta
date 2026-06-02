---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 3
from: claude
to: codex
created: 2026-05-28T21:00:00Z
status: open
expects_result_at: round-03-result.md
tracks: noetl/ai-meta#23
also_resolves: noetl/ai-meta#25
wait_phrase: "ship calendar cleanup phase c"
---

# Round 03 — gateway-side cleanup (#23 Phase C) + calendar.event.touched forwarding (#25)

> **Tracks:** [noetl/ai-meta#23](https://github.com/noetl/ai-meta/issues/23) (umbrella) and
> [noetl/ai-meta#25](https://github.com/noetl/ai-meta/issues/25) (additive SSE forwarding).
>
> **Predecessor:** Round 02 (`round-02-result.md`) shipped the SPA-side calendarSubscription
> module + orchestrator calendar.event.touched emit.  noetl/travel#56 merged
> (travel@44aed7f).  noetl-travel-wiki@153496f.  SPA is live on Cloudflare Pages and
> verified clean by direct orchestrator-turn smoke (exec 636832983227302164).

The travel SPA still has a dead-code `gatewaySubscriptions.ts` module and the gateway
still carries the entire `firestore_subscriptions` subsystem (the
`/api/subscriptions/firestore` route + `FirestoreSubscriptionManager` + the Python
listener helper) that nothing reads anymore.  Round 02 cut the SPA over to a
playbook-mediated transport but did NOT delete the old pipes.

Round 03 finishes the job:

1. Add `calendar.event.touched` to the gateway's forwarded SSE event-type allowlist
   so the SPA can listen on the *specific* signal instead of the generic
   `playbook.completed` it currently falls back to.  This closes
   noetl/ai-meta#25 (a tiny additive change).
2. Remove the gateway-side `firestore_subscriptions` subsystem entirely.
3. Remove the SPA-side `gatewaySubscriptions.ts` module + tests + the
   `events_path` field on the orchestrator's `calendar_view` widget envelope.
4. Update the gateway + travel + ops wikis per `agents/rules/wiki-maintenance.md`
   Rule 2 / 2b.

When Round 03 lands clean, noetl/ai-meta#23 closes for real (this time use
`Closes`, not `Closes ... Round 03`).

## Background — where to operate

- **Gateway code (Rust):**
  - `repos/gateway/src/playbook_state.rs:12` — `FORWARDED_EVENT_TYPES`
    constant.  Add `"calendar.event.touched"` to the list.
  - `repos/gateway/src/firestore_subscriptions.rs` — entire file (412 lines).
    Delete.
  - `repos/gateway/src/main.rs` — `mod firestore_subscriptions;` (line 27),
    `use crate::firestore_subscriptions::FirestoreSubscriptionManager` (line 40),
    construction at line 142, wiring at line 152, route registrations at lines
    228–233.  Delete all.
  - `repos/gateway/src/sse.rs:24,42,162` — `FirestoreSubscriptionManager`
    import + `firestore_subscriptions: Option<...>` field on the state struct +
    `subscriptions: state.firestore_subscriptions.is_some()` line.  Delete the
    field + the boolean it surfaces; update any constructor / response shape
    that mentioned it.
  - `repos/gateway/src/config/gateway_config.rs` — `firestore: FirestoreConfig`
    field on `ServerConfig` (line 29), the `FirestoreConfig` struct (line 99),
    the `Default::default()` initialiser (line 178), the `Default for
    FirestoreConfig` impl (line 243), and any `apply_env_overrides` branch
    that maps `GATEWAY_FIRESTORE_*` env vars onto it (grep for
    `GATEWAY_FIRESTORE_` to find).  Delete all.
  - `repos/gateway/scripts/firestore_listener.py` — the Python helper.  Delete.
  - Adjust `Cargo.toml` if any dep becomes unused after the removal (e.g.
    `firestore_*` crates).  Run `cargo check --release` to confirm clean build.

- **Travel SPA (TypeScript):**
  - `repos/travel/src/api/gatewaySubscriptions.ts` — delete.
  - `repos/travel/src/api/gatewaySubscriptions.test.ts` — delete.
  - `repos/travel/src/api/calendarSubscription.ts` — update the doc-comment
    references to gatewaySubscriptions; switch the SSE listener from
    `playbook/state` filtered on `playbook.completed` to listen on the new
    forwarded `calendar.event.touched` event type instead.  Keep
    `playbook.completed` as a fallback only if Codex judges it's still useful
    (e.g. when a turn completes without writing a calendar event — the
    refresh is still useful to clear loading states).
  - `repos/travel/src/contracts/widgets.ts` — `CalendarViewPayload.events_path:
    string` becomes optional (`events_path?: string`) or is removed entirely.
    Pick removed if no other widget references it; optional otherwise.  Run
    `./scripts/build_widget_contracts.sh` so the generated types match the
    source contract.
  - `repos/travel/playbooks/itinerary-planner.yaml` — drop `events_path` from
    both `calendar_view` widget emit sites (the orchestrator lines around 1289
    and 1299).  Round 01's preservation of the field is no longer needed.

- **Helm / ops:**
  - `repos/ops/automation/helm/gateway/values.yaml` — currently no explicit
    `firestore*` keys (grep returned nothing in recon).  But check
    `templates/deployment.yaml` for any `GATEWAY_FIRESTORE_*` env injection,
    GCP service-account credential mounts, or Firestore-related secrets;
    delete them if present.  Also check for a Python sidecar / init-container
    that ran the listener — delete that too.

- **Wikis (per `agents/rules/wiki-maintenance.md` Rule 2 / 2b — wiki edits
  ship in the SAME round as the code that changed):**
  - `repos/noetl-gateway-wiki/` — update / remove any page that documented
    `/api/subscriptions/firestore`.  Add a short page (or section on an
    existing page) on the SSE forwarded-event-types allowlist now that
    `calendar.event.touched` is part of it.  Update `Home.md` /
    `_Sidebar.md`.
  - `repos/noetl-travel-wiki/` — update the calendar / SPA-cutover pages
    (added in Round 02 at noetl-travel-wiki@153496f) to remove references to
    the old transport and document the final shape.
  - `repos/noetl-ops-wiki/` — update if the gateway-Firestore subsystem was
    documented (helm values, deployment shape).

## Branch + repo state

- Operate from each submodule's `main` HEAD as of ai-meta@344ec06.
- Create branches:
  - `kadyapam/round-03a-forward-calendar-event-touched` in `repos/gateway`
    (Phase C1 alone, small additive PR).
  - `kadyapam/round-03b-firestore-cleanup` in `repos/gateway` (Phase C2).
    Can ride alongside C1 in one PR if Codex prefers; rationale for
    splitting is risk-isolation (C1 is safe; C2 is destructive).  Use
    Codex's judgement.
  - `kadyapam/round-03-firestore-cleanup` in `repos/travel` (Phase C3, SPA
    cleanup + orchestrator `events_path` removal in the same submodule).
  - `kadyapam/round-03-firestore-cleanup` in `repos/ops` if the ops side has
    any cleanup to do.
- Wiki commits go directly to wiki `master` (no PR flow on wikis).

## Phases

### Phase C0 — sanity checks (no remote writes)

1. Confirm submodule sync clean: `git submodule status repos/gateway
   repos/travel repos/ops repos/noetl-gateway-wiki repos/noetl-travel-wiki
   repos/noetl-ops-wiki` shows no `+` / `-` prefix.  If it does, run
   `git submodule sync --recursive && git submodule update --init --recursive`
   from ai-meta root and re-check.
2. Confirm `repos/gateway/src/playbook_state.rs:12` still has the
   3-element `FORWARDED_EVENT_TYPES` array.  Capture the surrounding
   filter function in the final report so reviewers can see context.
3. Confirm `repos/travel/src/api/calendarSubscription.ts` still listens
   on `playbook.completed` (Round 02 state).
4. Confirm there are NO remaining consumers of `gatewaySubscriptions`
   outside `calendarSubscription.ts`'s doc-comment text — `grep -rn
   "subscribeToCalendarEvents\|gatewaySubscriptions" repos/travel/src/
   | grep -v calendarSubscription.ts | grep -v gatewaySubscriptions.ts`
   should return nothing.

### Phase C1 — gateway: add calendar.event.touched to forwarded SSE types

> Pure additive.  Closes noetl/ai-meta#25 once deployed.

5. Edit `repos/gateway/src/playbook_state.rs:12` to add
   `"calendar.event.touched"` to the `FORWARDED_EVENT_TYPES` slice.
6. Run `cargo check --manifest-path repos/gateway/Cargo.toml --release`
   from the ai-meta root (or `cd repos/gateway && cargo check --release`).
   Confirm clean.
7. If there are existing tests covering the SSE filter, run them.
8. Commit to branch `kadyapam/round-03a-forward-calendar-event-touched` in
   `repos/gateway`:

   ```
   feat(sse): forward calendar.event.touched on the gateway event channel

   Round 03 Phase C1 of noetl/ai-meta#23.  Adds the orchestrator-side
   calendar.event.touched event type to the gateway's FORWARDED_EVENT_TYPES
   allowlist so SPA clients can subscribe to it directly.  Before this
   change the event landed in the NoETL event log but never reached SSE
   clients — the travel SPA had to listen on the generic playbook.completed
   instead (Round 02 workaround).

   Closes noetl/ai-meta#25.
   Refs noetl/ai-meta#23.
   ```

### Phase C2 — gateway: delete the firestore_subscriptions subsystem

> Destructive.  Safe because Round 02 already removed all consumers; verify
> in Phase C0 step 4 before starting.

9. Delete `repos/gateway/src/firestore_subscriptions.rs`.
10. Delete `repos/gateway/scripts/firestore_listener.py`.
11. Edit `repos/gateway/src/main.rs` — remove the `mod` declaration, the
    `use` import, the construction call, the `firestore_subscriptions:
    Some(...)` wiring, and both route registrations (POST
    `/api/subscriptions/firestore` + DELETE
    `/api/subscriptions/{subscription_id}`).
12. Edit `repos/gateway/src/sse.rs` — remove the import + the
    `firestore_subscriptions: Option<...>` field + the
    `subscriptions:` boolean it surfaced in any response struct.
13. Edit `repos/gateway/src/config/gateway_config.rs` — remove the
    `firestore: FirestoreConfig` field, the `FirestoreConfig` struct, both
    `Default` impls, and any `apply_env_overrides` branch reading
    `GATEWAY_FIRESTORE_*` env vars.
14. Edit `Cargo.toml` to remove now-unused deps (if any — likely
    `firestore`, `google-cloud-*`, or similar; verify with
    `cargo machete` or by reading the deps list and grepping for usage).
15. Run `cargo check --manifest-path repos/gateway/Cargo.toml --release`.
    Run `cargo test --manifest-path repos/gateway/Cargo.toml --release`
    if there are tests touching the removed surface.
16. Commit to branch `kadyapam/round-03b-firestore-cleanup` in `repos/gateway`:

    ```
    feat(gateway): remove direct Firestore subscription subsystem

    Round 03 Phase C2 of noetl/ai-meta#23.  Removes the gateway-side
    Firestore data path that violated the gateway-is-gatekeeper-only
    rule (agents/rules/execution-model.md).  Round 02 already cut the
    travel SPA over to a playbook-mediated transport, leaving the
    /api/subscriptions/firestore route + FirestoreSubscriptionManager
    as dead code.

    Removed:
    - src/firestore_subscriptions.rs (412 lines)
    - scripts/firestore_listener.py
    - main.rs: mod declaration, route registrations, manager
      construction + wiring.
    - sse.rs: FirestoreSubscriptionManager import + state field +
      subscriptions: boolean.
    - config/gateway_config.rs: FirestoreConfig struct + ServerConfig
      field + Default impls + GATEWAY_FIRESTORE_* env handling.
    - Cargo.toml: dependencies that became unused.

    No backward-compat shim — Round 02 already removed the only consumer.

    Refs noetl/ai-meta#23.
    ```

### Phase C3 — travel SPA: delete gatewaySubscriptions + drop events_path

17. Delete `repos/travel/src/api/gatewaySubscriptions.ts`.
18. Delete `repos/travel/src/api/gatewaySubscriptions.test.ts`.
19. Edit `repos/travel/src/api/calendarSubscription.ts`:
    - Update the doc-comment header to remove references to
      "replaces gatewaySubscriptions.ts" (the predecessor is gone now).
    - Switch the SSE listener filter from
      `(event_type === "playbook.completed")` to
      `(event_type === "calendar.event.touched")`.  Codex's call: keep
      `playbook.completed` as a fallback if there's a clear case
      (turn completes without calendar write — the SPA might still
      want to refresh, e.g. to clear loading state).  Document the
      choice in the module header.
20. Edit `repos/travel/src/contracts/widgets.ts` `CalendarViewPayload`:
    remove `events_path: string` if no other code references it; otherwise
    mark optional.  Then regenerate generated types via
    `./scripts/build_widget_contracts.sh` (see `repos/travel/CLAUDE.md`).
21. Edit `repos/travel/playbooks/itinerary-planner.yaml` — remove
    `events_path` from both `calendar_view` widget envelopes (lines
    ~1289 and ~1299).  Confirm orchestrator still passes the smoke
    test from Round 02 (no events_path field is read anywhere
    upstream — Round 02 already moved the SPA off it).
22. Run `npm run lint` (tsc --noEmit) — confirm clean.
23. Run `npm run build` — confirm clean.
24. Commit to branch `kadyapam/round-03-firestore-cleanup` in
    `repos/travel`:

    ```
    feat(spa): remove gatewaySubscriptions + events_path; listen on calendar.event.touched

    Round 03 Phase C3 of noetl/ai-meta#23.  Completes the SPA-side
    cutover that Round 02 started:

    - Delete src/api/gatewaySubscriptions.ts and its test (no remaining
      consumers — Round 02 removed the last one in CalendarView.tsx).
    - Switch calendarSubscription's SSE filter from playbook.completed
      to calendar.event.touched, the specific signal the orchestrator
      emits.  Forwarded by the gateway as of gateway PR for
      noetl/ai-meta#25.
    - Drop events_path from the CalendarViewPayload contract and from
      the orchestrator's emit sites in playbooks/itinerary-planner.yaml.

    Refs noetl/ai-meta#23.
    ```

### Phase C4 — ops: drop Firestore env/secrets from gateway deployment

25. Inspect `repos/ops/automation/helm/gateway/templates/deployment.yaml`
    + `values.yaml` for `GATEWAY_FIRESTORE_*` env vars, GCP service-
    account credential mounts referenced only by Firestore, and any
    sidecar/init-container running `firestore_listener.py`.
26. If found, delete the env vars + the mount + the sidecar.  If the
    helm chart has nothing to clean up (recon suggests this), record
    "no ops cleanup required" in the result.
27. If changes were made, commit to branch
    `kadyapam/round-03-firestore-cleanup` in `repos/ops` with:

    ```
    chore(helm/gateway): drop unused Firestore env + listener sidecar

    Round 03 Phase C4 of noetl/ai-meta#23.  The gateway no longer reads
    GATEWAY_FIRESTORE_* env vars after the noetl/gateway cleanup PR
    landed; remove the unused values from the gateway deployment.

    Refs noetl/ai-meta#23.
    ```

### Phase C5 — wikis

> Per `agents/rules/wiki-maintenance.md` Rule 2 + 2b — wiki edits ship in
> the SAME round as the code that changed them.  Push wiki edits directly
> to `master` (wikis don't take PRs).

28. `repos/noetl-gateway-wiki/`:
    - Remove or strikethrough any page documenting
      `/api/subscriptions/firestore` and `FirestoreSubscriptionManager`.
    - Add or extend a page documenting `FORWARDED_EVENT_TYPES`
      (the SSE event-type allowlist) including the new
      `calendar.event.touched` entry.  Cross-link from `Home.md` /
      `_Sidebar.md`.
29. `repos/noetl-travel-wiki/`:
    - Update the SPA cutover page (added in Round 02 at
      noetl-travel-wiki@153496f) to remove references to
      `gatewaySubscriptions.ts` and document the final
      `calendar.event.touched` listener shape.  Remove
      `events_path` mentions from any page that described the
      widget contract.
30. `repos/noetl-ops-wiki/`:
    - If a page documented the gateway-Firestore deployment, update
      it to reflect the cleanup.  If no page exists, no change.
31. Commit each wiki repo separately with messages of the form:

    ```
    wiki(gateway): document SSE forwarded-event-types + remove firestore_subscriptions
    wiki(travel): finalise calendar cutover (events_path dropped; calendar.event.touched listener)
    wiki(ops): remove gateway-Firestore deployment notes  # if applicable
    ```

### Phase C6 — local commits done; STOP and wait for the dispatcher

32. **STOP HERE.**  Do NOT push any branches, do NOT push wiki
    masters, do NOT open any PRs, do NOT do any GKE work.  Write the
    final report at `round-03-result.md`, listing the local SHA of every
    commit you created (gateway branch C1, gateway branch C2, travel
    branch C3, ops branch C4 if any, plus the wiki commits at C5).

### Phase C7 — push + open PRs

> ***Run only after explicit human go-ahead.  Wait phrase: `ship calendar cleanup phase c`.***

33. Push each branch + each wiki master.
34. Open PRs:
    - `noetl/gateway`: one PR per branch (or one combined PR if Codex
      kept C1+C2 on the same branch).  Body cites
      noetl/ai-meta#23 + noetl/ai-meta#25.  PR for C1 includes
      `Closes noetl/ai-meta#25` in the body.  PR for C2 includes
      `Refs noetl/ai-meta#23` (NOT `Closes` — there's still the
      ops + travel + wiki side to land before #23 fully closes; see
      commit-conventions.md "Critical" callout on the Closes-keyword
      caveat).
    - `noetl/travel`: PR for C3 cites `Refs noetl/ai-meta#23`.
    - `noetl/ops`: PR for C4 cites `Refs noetl/ai-meta#23` (if there
      were any ops changes).
35. Do NOT merge any PR yourself.

### Phase C8 — GKE smoke after all PRs merge + new gateway image deploys

> ***Run only after explicit human go-ahead.  Wait phrase: `verify calendar cleanup on gke`.***

36. Once all PRs merge and the dispatcher rebuilds + redeploys the gateway
    image, run an SPA-style smoke turn against gke-prod (the orchestrator
    turn pattern from Round 02's verification).
37. Confirm the SSE stream includes a `calendar.event.touched` frame
    after the turn writes a calendar event.
38. Confirm `/api/subscriptions/firestore` returns 404 (route removed).
39. Confirm the calendar.event.touched event survives end-to-end:
    orchestrator emit → NoETL event log → gateway forwarding → SPA
    listener.

## FINAL REPORT

Write `round-03-result.md` with frontmatter:

```yaml
---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 3
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-03-prompt.md
status: complete | partial | blocked
---
```

One H2 per phase plus the standard `Issues observed` and `Manual escalation
needed` sections.

## Hard rules for this thread

- Never push to `origin/main` on any repo unless this prompt explicitly says so
  (Phase C7 + C8 are explicitly gated).
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`.  Especially:
  - `agents/rules/execution-model.md` — the boundary this round is enforcing.
  - `agents/rules/wiki-maintenance.md` Rule 2 + 2b — wikis ship in the same
    round as the code.
  - `agents/rules/issue-tracking.md` Rule 1 + 2 + 1b — PR bodies cite the
    issues; pointer bumps cite the issues; multi-round umbrellas use `Refs`
    not `Closes`.
  - `agents/rules/commit-conventions.md` — the "Critical" callout on
    `Closes` keyword behaviour (added today at ai-meta@783b6a0).
- Do not store secrets in any file under ai-meta (the repo is public).
- If a step's preconditions aren't met, stop and report — don't improvise
  around blockers.
- Do not touch `repos/noetl/` (the Python worker / server) in this round —
  the calendar.event.touched emit lives in `repos/travel/playbooks/`
  (orchestrator YAML), not in noetl/noetl.
