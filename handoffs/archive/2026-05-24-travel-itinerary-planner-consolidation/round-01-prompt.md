---
thread: 2026-05-24-travel-itinerary-planner-consolidation
round: 1
from: claude
to: codex
created: 2026-05-24T18:55:00Z
status: open
expects_result_at: round-01-result.md
---

# Consolidate itinerary-planner playbook + add mcp/firestore batch methods

> **Predecessors:**
> - Production incident: a single itinerary-planner run took
>   **10m 24s** under cluster contention; warm-baseline runs
>   take **~10s**. Recorded in the 2026-05-24 incident memory
>   and surfaced via "Execution `633631566496792709` did not
>   complete in time" in the SPA.
> - Architecture principle now codified at
>   `repos/docs/docs/architecture/ephemeral_blueprints.md`
>   (merged via noetl/docs#169) and
>   `agents/rules/execution-model.md`. The principle calls out
>   "collapse trivial `tool: agent` chains into batched MCP
>   calls" as the playbook-side latency answer.
> - Pre-existing precedent: `auth0_login_optimized.yaml`
>   collapsed 7 steps into 3 using a Postgres CTE (~3s → ~1s).
>   The travel orchestrator deserves the same treatment via
>   the firestore MCP.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose), and
`agents/rules/wiki-maintenance.md` before starting.

## Why this round exists

The travel itinerary-planner playbook
([`repos/travel/playbooks/itinerary-planner.yaml`](https://github.com/noetl/travel/blob/main/playbooks/itinerary-planner.yaml))
has 16+ steps. Most are `tool: agent` calls into
[`repos/ops/automation/agents/mcp/firestore.yaml`](https://github.com/noetl/ops/blob/main/automation/agents/mcp/firestore.yaml)
doing one document write or read each. Each such step pays the
full NoETL per-step overhead (NATS roundtrip, ~7 event writes,
nested-playbook dispatch, child event writes, completion
events). That overhead is ~100–600ms per step depending on
nested depth. With 16 sequential steps the warm-baseline lands
around **10s** for a turn that should be sub-second.

The fix is not on the platform side this round. The platform-
level optimization (event batching, inline trivial children) is
a separate, larger handoff. This round addresses the playbook-
side opportunity: **collapse trivial firestore writes into
batched MCP calls** so 16 sequential nested playbooks become
3–5.

## What this round delivers

1. **New batch methods in
   `repos/ops/automation/agents/mcp/firestore.yaml`:**
   - `batch_append_events` — accepts a list of `{thread_path,
     event}` pairs and writes them in one MCP invocation.
   - `batch_set_docs` — accepts a list of `{path, doc}` pairs
     and writes them in one MCP invocation.
   - `batch_get_docs` — accepts a list of `{path}` and returns
     them keyed by path (optional; only add if it removes ≥1
     parent step in itinerary-planner).
   The internal implementation may either fan out to multiple
   Firestore REST calls inside the MCP playbook (still saves
   parent-side overhead) or call Firestore's
   `commits.batchWrite` API once. Choose based on what is
   simpler; record the choice in the result.

2. **Rewritten `repos/travel/playbooks/itinerary-planner.yaml`**
   that uses the batched MCP methods. Target structure (codex
   chooses the exact partition):
   - `normalize_input` (python, unchanged)
   - `extract_turn_with_state` — combines `load_slot_state` +
     `extract_turn` into a single step (or keeps them separate
     if the LLM call needs state pre-fetched independently;
     codex decides).
   - `call_<provider>` (one step, unchanged) — the tool call
     itself is irreducible.
   - `normalize_tool_response` (python, unchanged) — but
     emits a single dict that downstream steps consume.
   - `persist_turn_atomically` — one `batch_set_docs` call
     that updates slot_state, persists tool_slot_state,
     persists api_call.
   - `append_turn_events_atomically` — one `batch_append_events`
     call writing all of: input_event, slot_update_event,
     tool_call_event, tool_response_event, widget_event.
   - `render_widget_chat` (python, unchanged).
   - `persist_calendar_events_atomically` (if any) — one
     `batch_set_docs` call for the trip's calendar entries.
   - `final_result` (python, unchanged).
   The expected step count drops from 16+ to roughly 6–8.

3. **Target warm-baseline duration: under 2s** for a single-
   provider turn. The current ~10s baseline should drop by
   ~5×. Codex measures and reports the actual delta.

4. **Wiki updates** (mandatory per `agents/rules/wiki-maintenance.md`):
   - `repos/noetl-travel-wiki/playbook-itinerary-planner.md` —
     update the step inventory, workload contract, performance
     notes to reflect the consolidated playbook. The current
     page documents the 16-step shape; rewrite the affected
     sections.
   - `repos/noetl-ops-wiki/` — add a new page covering the
     firestore MCP (it has no wiki coverage today). Page slug
     suggestion: `agents-mcp-firestore`. Document the existing
     methods and the new batch methods, the path-scope rules,
     the credentials it pulls from the keychain, and how the
     gateway's Firestore Admin sidecar (the Python listener
     introduced in `noetl/gateway#11`) relates to it (the MCP
     handles writes/reads from within playbooks; the gateway
     sidecar handles live read subscriptions for the SPA —
     two different code paths, same underlying Firestore).

5. **Three PRs (do not merge):**
   - `noetl/ops` — firestore MCP batch methods.
   - `noetl/travel` — consolidated itinerary-planner.
   - Wiki pushes are direct to `master` on the two wiki repos
     (no PRs).

6. **Result file** at
   `handoffs/active/2026-05-24-travel-itinerary-planner-consolidation/round-01-result.md`.

## Phases

### Phase A — sync + baseline

1. Sync submodules to current main:
   ```
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull --ff-only origin main
   git -C repos/travel fetch origin && git -C repos/travel checkout main && git -C repos/travel pull --ff-only origin main
   git -C repos/noetl-travel-wiki fetch origin && git -C repos/noetl-travel-wiki checkout master && git -C repos/noetl-travel-wiki pull --ff-only origin master
   git -C repos/noetl-ops-wiki fetch origin && git -C repos/noetl-ops-wiki checkout master && git -C repos/noetl-ops-wiki pull --ff-only origin master
   ```
2. Read the playbook end-to-end:
   `repos/travel/playbooks/itinerary-planner.yaml`. Record:
   - exact step count today,
   - which steps are `tool: agent` into `mcp/firestore`,
   - which steps' outputs are consumed by which downstream
     steps (data dependencies).
3. Read the firestore MCP playbook end-to-end:
   `repos/ops/automation/agents/mcp/firestore.yaml`. Record
   the methods it currently exposes and how they handle auth /
   path-scope / errors.
4. Establish a baseline duration. Either pull recent
   `muno/playbooks/itinerary-planner` execution durations from
   `kubectl exec -n noetl deploy/noetl-server -- curl -s
   "http://127.0.0.1:8082/api/executions?path=muno/playbooks/itinerary-planner&limit=5"`
   OR run a synthetic warm-path execution and time it. Aim
   for 2–3 reference numbers under low contention.
5. Snapshot the result in the report.

### Phase B — add batch methods to mcp/firestore (ops branch)

6. Branch `repos/ops`:
   ```
   git -C repos/ops checkout -b kadyapam/mcp-firestore-batch-methods
   ```
7. Add `batch_append_events`, `batch_set_docs`, and (if
   warranted) `batch_get_docs` to
   `automation/agents/mcp/firestore.yaml`. Match the existing
   method dispatch pattern in that playbook. Each batch method:
   - Validates the request payload shape.
   - Performs all the underlying writes/reads in one MCP
     invocation. If the implementation fans out internally to
     N Firestore REST calls, that is fine — the parent-side
     overhead reduction is still the win. If the Firestore
     `commits.batchWrite` API is straightforward to use from
     the playbook, prefer it.
   - Returns a single response with per-item status.
8. Add a minimal test fixture or smoke step that exercises
   each new method. If the ops repo has a test harness for MCP
   playbooks, use it. If not, document the manual smoke command
   in the PR body.
9. Commit:
   ```
   git -C repos/ops add automation/agents/mcp/firestore.yaml
   git -C repos/ops commit -m "feat(mcp/firestore): batch_append_events + batch_set_docs"
   git -C repos/ops push -u origin kadyapam/mcp-firestore-batch-methods
   ```
10. Open the PR with `gh pr create --repo noetl/ops`. Body must
    cover:
    - Why (link the ai-meta architecture doc + this thread's
      memory entry).
    - The new method signatures.
    - The chosen implementation (per-method fan-out vs. native
      Firestore batchWrite).
    - Reference the travel playbook PR opened in Phase C.

### Phase C — consolidate itinerary-planner (travel branch)

11. Branch `repos/travel`:
    ```
    git -C repos/travel checkout -b kadyapam/itinerary-planner-consolidation
    ```
12. Rewrite `playbooks/itinerary-planner.yaml`:
    - Map each cluster of trivial `tool: agent` steps to a
      single `tool: agent` call into one of the new batch
      methods.
    - Preserve all data-flow dependencies: the consolidated
      step must run only after all of its input data is
      computed.
    - Preserve the playbook's policy block, retry rules, and
      error handling. The consolidation is structural, not
      behavioral; the same final state must be reached.
    - Update inline comments where structure changes
      materially.
13. Re-run the existing smoke / test harness in
    `repos/travel`:
    ```
    npm test
    npm run type-check
    npm run lint
    npm run smoke:widgets
    npm run build
    ```
    All must pass.
14. Live validation against the GKE cluster (pre-authorized
    this round):
    - Register the consolidated playbook with the noetl-server
      catalog under a temporary path
      `muno/playbooks/itinerary-planner-consolidated` (so the
      live `itinerary-planner` keeps serving until codex
      verifies the new one).
    - Run 3–5 synthetic turns against the consolidated playbook
      (e.g., "trip to Paris", "trip to Tokyo", "trip to
      Lisbon"). Time each one.
    - Confirm the playbook completes (no failed steps), emits
      the same widget envelopes the unconsolidated version
      does, and produces the same Firestore writes
      (spot-check 1–2 documents).
    - If validation passes, the PR can flip the existing
      playbook path. If validation fails, leave both versions
      in place and report the failure in the result.
15. Commit:
    ```
    git -C repos/travel add playbooks/itinerary-planner.yaml
    git -C repos/travel commit -m "feat(playbook): consolidate itinerary-planner with batched firestore MCP"
    git -C repos/travel push -u origin kadyapam/itinerary-planner-consolidation
    ```
16. Open the PR with `gh pr create --repo noetl/travel`. Body
    must cover:
    - Why (link architecture doc + ops PR from Phase B).
    - Step count before/after (table).
    - Measured duration before/after (table).
    - What did not change (workload contract, widget output,
      Firestore record shape).
    - Mention the wiki updates landed in Phase E.

### Phase D — wiki updates (mandatory)

17. Travel wiki — `repos/noetl-travel-wiki/playbook-itinerary-planner.md`:
    - Rewrite the "Workflow steps (in order)" table to reflect
      the consolidated playbook.
    - Update the "Performance notes" section: pre-consolidation
      baseline (~10s), post-consolidation baseline (target <2s),
      the technique used (batched MCP), and the link to the
      ops MCP page.
    - Update the "Where each pattern lives" section if a
      pattern moved (e.g. "Slot state as projection" still
      true, but now persisted in one batched call).
18. Ops wiki — new page `repos/noetl-ops-wiki/agents-mcp-firestore.md`:
    - Frame: this is the firestore MCP playbook used by all
      domain orchestrators that need Firestore.
    - Methods (with signatures): `get_doc`, `set_doc`,
      `append_event`, `batch_append_events`, `batch_set_docs`,
      `batch_get_docs` (if added). Document each one's
      request/response.
    - Auth and path-scope rules.
    - Credentials from keychain (e.g. firebase service
      account stored as a credential reference; do not paste
      the credential).
    - Relationship to the gateway-side Firestore subscription
      sidecar (the gateway's Python sidecar for live SSE
      subscriptions is separate code; the MCP handles
      playbook-side reads/writes; both talk to the same
      Firestore project).
    - Cross-link to the new travel wiki playbook page and the
      [Ephemeral Blueprints](https://github.com/noetl/docs/blob/main/docs/architecture/ephemeral_blueprints.md)
      doc.
19. Update `repos/noetl-ops-wiki/Home.md` and `_Sidebar.md` to
    surface the new page.
20. Push both wikis (direct to `master`):
    ```
    git -C repos/noetl-travel-wiki add playbook-itinerary-planner.md
    git -C repos/noetl-travel-wiki commit -m "wiki(playbook): reflect itinerary-planner consolidation"
    git -C repos/noetl-travel-wiki push origin master

    git -C repos/noetl-ops-wiki add agents-mcp-firestore.md Home.md _Sidebar.md
    git -C repos/noetl-ops-wiki commit -m "wiki(agents): add firestore MCP page"
    git -C repos/noetl-ops-wiki push origin master
    ```

### Phase E — write result

21. Write
    `handoffs/active/2026-05-24-travel-itinerary-planner-consolidation/round-01-result.md`.

    Required sections:
    ```
    ## Phase A — sync + baseline
    ## Phase B — mcp/firestore batch methods
    ## Phase C — itinerary-planner consolidation
    ## Phase D — wiki updates
    ## Performance delta
    ## Issues observed
    ## Manual escalation needed
    ```

    Include:
    - Baseline durations (3–5 reference numbers).
    - Post-consolidation durations (3–5 reference numbers).
    - Step count before/after.
    - PR URLs (ops + travel).
    - Wiki commit SHAs (`noetl-travel-wiki`, `noetl-ops-wiki`).
    - The chosen implementation strategy for batch methods.
    - Any data-flow re-orderings that were required.

22. Commit + push the result in `ai-meta`.

## Hard rules for this thread

- **Do not merge any PR.** Open both, link both, stop.
- **Do not commit secrets** — no Firebase service-account JSON,
  no Auth0 client secret, no NATS credentials in any file
  under ai-meta or any wiki. Reference credentials by alias
  through the keychain.
- **Do not force-push** on any branch.
- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- **The wiki updates are mandatory**, not optional. If you skip
  the wikis or leave them for "later", the round is not
  complete. See `agents/rules/wiki-maintenance.md` Rule 1b
  (bump → wiki update is a single coordinated change).
- **Behavioral equivalence is mandatory.** The consolidated
  playbook must emit the same widget envelopes, write the
  same Firestore records (modulo write ordering), and respect
  the same policy/retry semantics. If any behavior changes
  meaningfully, stop and flag in the result instead of
  shipping the change.
- **Live validation is pre-authorized.** You may register
  the consolidated playbook under a temporary path and run
  synthetic turns against the cluster. Do not delete the
  existing `muno/playbooks/itinerary-planner` until the
  travel PR is merged.

## What success looks like

- Ops PR open with new MCP batch methods; tests pass.
- Travel PR open with consolidated itinerary-planner;
  npm test / type-check / lint / build / smoke all pass;
  3–5 live cluster turns measured.
- Per-turn warm-baseline drops by ≥3× (target ≥5×).
- Travel wiki page updated to reflect new structure.
- New ops wiki page covering the firestore MCP, including
  the new batch methods, linked from Home and Sidebar.
- Result file written and pushed.

## What is explicitly out of scope

- Platform-side per-step event batching in `repos/noetl`
  (separate handoff).
- `/api/executions` listings stale-status bug fix
  (separate handoff).
- Gateway-side changes.
- Adding new providers (Duffel/Amadeus/Google/Ollama)
  alongside this round.
- Schema changes to Firestore documents.
