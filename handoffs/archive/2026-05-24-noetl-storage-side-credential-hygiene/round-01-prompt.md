---
thread: 2026-05-24-noetl-storage-side-credential-hygiene
round: 1
from: claude
to: codex
created: 2026-05-24T20:55:00Z
status: open
expects_result_at: round-01-result.md
---

# Storage-side credential hygiene: persist references, not resolved values

> **Predecessor:**
> `handoffs/archive/2026-05-24-noetl-keychain-leak-redaction/round-01-result.md`
> (or its currently-active path under `handoffs/active/` if the
> redaction PR has not closed yet). Issue #1 in that round:
>
> > "Storage-side hygiene remains open: resolved credential values can
> > still exist in workflow state, event payloads, command context,
> > result refs, or temp refs. This round masks reads; it does not
> > alter storage behavior."
>
> This handoff closes that gap.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose), and
`agents/rules/wiki-maintenance.md` (Rule 1b — wiki rides with
the pointer bump).

## Why this round exists

PR `noetl/noetl#603` (the predecessor round's result) added
output-side redaction at every HTTP serialization boundary in
the noetl-server. Reads are now safe. The stored data is not.

The stored payloads in `workflow_state`, `event`, `command`,
`result_store`, and `temp_store` still contain cleartext
resolved keychain values, user bearer tokens, and other
secret-shaped strings. That means:

- Any future endpoint that adds serialization without going
  through the redaction helpers will leak again.
- Anyone with direct database access (operators, debug
  sessions, replay tooling) sees cleartext.
- Backups, log exports, and audit dumps carry cleartext.
- Replay against the event log re-materializes cleartext into
  in-process state.

The architecturally-correct fix is to **never persist resolved
values** in the first place. Persist references; resolve from
the keychain at every use (which is already what tool
execution does in-process — see the ephemeral-blueprints
architecture doc).

## What this round delivers

1. **An audit + design report** in the result, listing every
   storage location that today receives a resolved keychain
   value, and proposing the new shape (reference + resolver
   pattern).
2. **A new persistence contract.** Resolved keychain values
   are never persisted into `workflow_state`, `event`,
   `command`, `result_store`, or `temp_store`. References are
   persisted instead. Tool dispatch resolves the reference
   from the keychain at the point of use.
3. **Migration policy** for existing data:
   - **No retroactive rewrite of existing rows.** The
     read-side redaction patch (PR #603) keeps already-
     persisted cleartext from leaving the HTTP boundary.
     Rewriting historical event-log rows would violate the
     event log's immutability invariant.
   - The new behavior applies to **new executions only**
     from the merged-PR cut-off forward.
4. **Reference resolution semantics.** A persisted reference
   must:
   - round-trip through serialization (JSON, Postgres
     `jsonb`) without loss,
   - be distinguishable from cleartext at the type level
     (not just "a string that looks like Jinja"),
   - resolve from the keychain at every use, with caching
     bounded by the worker's existing keychain cache.
5. **Tests:**
   - Unit tests pinning the reference type and resolver.
   - Integration tests over a new execution that proves
     stored state never contains the cleartext value.
   - Compatibility tests proving read-side redaction (from
     PR #603) is still effective for any path that does
     happen to surface old data.
6. **Live verification** on GKE — run a fresh execution
   with the patched image, query the database directly
   (through the existing in-cluster tooling), confirm the
   stored payloads carry references not cleartext.
7. **Wiki update** per Rule 1b — extend
   `repos/noetl-wiki/secrets-and-redaction` (the page added
   by the predecessor round) with the new persistence
   contract, the reference shape, and the resolver behavior.
8. **One PR on `noetl/noetl`** (do not merge).
9. **Result file** at
   `handoffs/active/2026-05-24-noetl-storage-side-credential-hygiene/round-01-result.md`.

## Phases

### Phase A — sync + audit (read-only)

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only origin main
   git -C repos/noetl-wiki fetch origin && git -C repos/noetl-wiki checkout master && git -C repos/noetl-wiki pull --ff-only origin master
   ```
   `repos/noetl` should include the merged PR #603 (response-
   boundary redaction). If it does not, stop and surface that
   the redaction PR has not landed yet.

2. **Audit every storage seam** where resolved values can
   land. Inventory:
   - The Jinja resolver path. Where in
     `noetl/core/workflow/...` does template rendering
     resolve `{{ keychain.X.Y }}` into a literal string?
     Which downstream code receives the resolved string?
   - `workflow_state` table — what column shapes hold
     `variables`? Where is the write?
   - `event` / `event_log` tables — `context`, `result`,
     `error` payloads. Where are they written?
   - `command` table — `context`, `meta`. Where are they
     written?
   - Result store (`result/{execution_id}/{step_name}` —
     persisted refs and inline values). Where written?
   - Temp store (`temp/{execution_id}/{name}`). Where
     written?
   - Any Arrow IPC / shared-cache surface that materializes
     resolved values (`noetl/core/cache/...`).

3. Trace one **concrete example** end-to-end. Pick a
   playbook step like `extract_turn` in
   `repos/travel/playbooks/itinerary-planner.yaml` that
   references `{{ keychain.openai_token.api_key }}`. Walk
   from the playbook YAML → workflow resolver → tool input
   → event log write. Document every line where the
   resolved literal lives in memory.

4. Produce the audit table in the result file. Columns:
   - Storage seam (table + column / cache key pattern).
   - Field shape today (what it contains for a keychained
     reference).
   - What it should contain after the change.
   - Risk if missed (what leaks).

### Phase B — design selection

5. Branch `repos/noetl`:
   ```
   git -C repos/noetl checkout -b kadyapam/storage-side-credential-hygiene
   ```

6. Decide the **reference type**. Two viable shapes; pick
   one and document the choice:
   - **(i) Tagged dict**:
     `{"$keychain_ref": "openai_token.api_key"}` — JSON-
     visible, type-discriminable, easy to redact-on-read as
     a safety net.
   - **(ii) Opaque token**: a wrapper class
     `KeychainRef("openai_token.api_key")` that serializes
     to a structured JSON form on disk but is a distinct
     Python type in memory.
   - **(iii) Sentinel string**: `<<keychain_ref:openai_token.api_key>>`
     — simplest to retrofit but harder to distinguish
     from intentional user data.

   Codex picks based on what minimizes downstream churn. The
   architecture preference is option (i) or (ii); avoid
   (iii) unless it removes >> 50% of the implementation
   surface.

7. Decide **when resolution happens**:
   - **Lazy** — every read from storage that needs the value
     resolves through the keychain.
   - **Eager at tool dispatch** — the worker's tool dispatch
     layer resolves all references in the step's input
     before invoking the tool. The tool sees cleartext;
     storage does not. Recommended unless the audit reveals
     a non-tool path that needs the literal value.

8. Decide whether to introduce a **central resolver
   utility** in `noetl/core/keychain/` (or wherever the
   keychain lives today). Document the interface.

### Phase C — implement the new persistence contract

9. **Stop persisting resolved values** at every seam
   identified in Phase A. The Jinja resolver path that
   today materializes `{{ keychain.X.Y }}` into a literal
   string must instead leave the reference in place when
   the destination is a storage write. The tool dispatch
   path must resolve references when the destination is a
   tool's input.

10. Add the central resolver. Worker-side keychain access
    funnels through it. The resolver:
    - Reads the keychain via the existing client.
    - Caches resolved values per-worker bounded by an
      existing cache (do not add a new long-lived cache).
    - Returns cleartext to the caller.
    - Has no path that writes cleartext to disk.

11. Modify the workflow-state writer so the persisted
    `variables` map carries references where keychain
    values appear. Same for event payload writes, command
    context writes, result-store writes, temp-store writes.

12. Confirm the **read-side redaction (PR #603) still
    fires** for any path that does happen to read a
    pre-change event row carrying historical cleartext.
    The redaction is a belt-and-suspenders safety net; do
    not remove it.

### Phase D — tests + verification

13. Add or update tests:
    - Unit: the new reference type / resolver round-trips
      through JSON and `jsonb`.
    - Integration: run a synthetic execution that uses
      `{{ keychain.X.Y }}`. After completion, assert:
      - `workflow_state.variables` for that execution
        contains the reference, not cleartext.
      - Every `event` row for that execution carries the
        reference in `context` / `result` / `error`,
        never cleartext.
      - The tool actually received cleartext at dispatch
        time (mock the tool, capture the input).
    - Compatibility: a synthetic pre-change event-log row
      with cleartext still serializes through the
      redaction helpers cleanly (i.e. PR #603's safety net
      remains effective).

14. Run the full noetl test suite. Document new failures
    (if any) and any pre-existing failures that overlap
    with the changed surface.

### Phase E — live cluster validation

15. Pre-authorized: build the new image (Cloud Build) and
    deploy via `helm upgrade --reuse-values --set image.tag=<tag>`.
    The current live cluster runs the temporary tag
    `keychain-redaction-69d55d40-20260524125244` from the
    predecessor round; this round bumps it forward.

16. Run a synthetic execution against the cluster that
    uses a keychain credential
    (`muno/playbooks/itinerary-planner` or similar — your
    pick).

17. Query the database directly through `kubectl exec`
    against the noetl-server pod (using the Postgres
    pooler the server already has access to):
    - `select variables from noetl.workflow_state where execution_id = <id>` — assert no cleartext.
    - `select context, result from noetl.event where execution_id = <id> limit 20` — assert no cleartext.
    - `select context from noetl.command where execution_id = <id> limit 20` — assert no cleartext.

18. Capture the before/after in the result with placeholder
    redactions. **Never paste the actual values.**

### Phase F — wiki update (mandatory per Rule 1b)

19. Extend `repos/noetl-wiki/secrets-and-redaction.md` (the
    page added in the predecessor round) with:
    - The persistence contract: references in storage,
      cleartext only at tool dispatch.
    - The reference shape (whichever option Phase B chose).
    - The resolver interface.
    - The migration policy (no retroactive rewrite of
      historical rows; new executions only).
    - Cross-link to the `agents/rules/execution-model.md`
      secrets-and-credentials rule.

20. Update `repos/noetl-wiki/Home.md` and `_Sidebar.md`
    if section structure changed.

21. Commit + push the wiki:
    ```
    git -C repos/noetl-wiki add -A
    git -C repos/noetl-wiki commit -m "wiki(security): persistence contract — references in storage"
    git -C repos/noetl-wiki push origin master
    ```

### Phase G — open PR + write result

22. Commit the noetl changes + push:
    ```
    git -C repos/noetl add -A
    git -C repos/noetl commit -m "fix(security): persist keychain references; never cleartext"
    git -C repos/noetl push -u origin kadyapam/storage-side-credential-hygiene
    ```
23. Open draft PR with `gh pr create --repo noetl/noetl`.
    Body must cover:
    - Why (link the predecessor round's wiki page).
    - The reference shape chosen + rationale.
    - The resolver interface.
    - Endpoints / writers patched.
    - Migration policy.
    - Live verification (with placeholder redactions).
    - Tests.
    - Reference the noetl-wiki commit.

24. Write
    `handoffs/active/2026-05-24-noetl-storage-side-credential-hygiene/round-01-result.md`.

    Required sections:
    ```
    ## Phase A — audit
    ## Phase B — design decisions
    ## Phase C — writers patched
    ## Phase D — tests
    ## Phase E — live validation
    ## Phase F — wiki update
    ## Issues observed
    ## Manual escalation needed
    ```

25. Commit + push the result in `ai-meta`.

## Hard rules for this thread

- **Do not merge the PR.** Open as draft, link, stop.
- **Never include the leaked values themselves** in any file
  under ai-meta or in any wiki, PR body, or commit message.
  Use placeholders. The ai-meta repo is public.
- **Do not retroactively rewrite event-log rows.** The event
  log is immutable. Old cleartext stays where it is and
  relies on the PR #603 read-side redaction.
- **Do not remove the read-side redaction from PR #603.** It
  is the safety net for historical data and any future
  serialization seam.
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- **Live cluster operations are pre-authorized this round**
  for the patched-image build, helm upgrade, and DB-side
  verification queries. Do not pre-authorize anything else.
- **Wiki update is mandatory.** If Phase F cannot land in
  this round, file the round as `partial` with a clear
  blocker.
- **If the audit in Phase A reveals the scope is bigger
  than one round can handle**, write the design
  recommendation as the round-01 result and stop before
  Phase C. The user opens the next round with the agreed
  design.

## What success looks like

- New executions write references to storage. Cleartext
  never reaches `workflow_state` / `event` / `command` /
  `result_store` / `temp_store` for keychain-resolved
  values.
- Tool dispatch resolves references just-in-time so tools
  see the cleartext they need to function.
- Live cluster shows references in the database for a
  fresh execution.
- Old data stays in place; read-side redaction continues to
  protect HTTP outputs.
- Draft PR open on `noetl/noetl`.
- Wiki updated.

## Out of scope (separate handoffs)

- Platform-side per-step event batching / inline trivial
  children (still queued separately).
- `/api/executions?limit=N` listings stale-status bug
  (still queued separately).
- Gateway-side or SPA-side changes.
- Schema migrations to backfill historical event rows
  (intentionally not done; event log immutability).
