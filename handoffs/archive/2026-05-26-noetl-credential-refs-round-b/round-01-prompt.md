---
thread: 2026-05-26-noetl-credential-refs-round-b
round: 1
from: claude
to: codex
created: 2026-05-26T02:30:00Z
status: open
expects_result_at: round-01-result.md
---

# Round B credential hygiene — producer-side hardening

> **Predecessors (both archived, both merged):**
> - `handoffs/archive/2026-05-24-noetl-keychain-leak-redaction/`
>   → noetl/noetl#603 → v2.100.6. Read-side redaction at every
>   HTTP serialization boundary.
> - `handoffs/archive/2026-05-24-noetl-storage-side-credential-hygiene/`
>   → noetl/noetl#604 → v2.100.7. Round A: stop persisting
>   resolved keychain values in `state.variables`, command
>   context, and event payloads. References stored as
>   `$noetl_ref`; mixed templates deferred; worker dispatch
>   resolves just before tool execution; worker scrubs the
>   keychain namespace from the result before persistence and
>   event emission.
>
> Both halves of the keychain credential boundary now hold
> for the **structured fields** (`state.variables`, command
> context, event context/result, execution state). This round
> closes the remaining producer-side surfaces that those rounds
> intentionally left out.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose), and
`agents/rules/wiki-maintenance.md` (Rule 1b — wiki rides with
the pointer bump).

Re-read the round-02 result of the storage-side-hygiene thread
(archived path
`handoffs/archive/2026-05-24-noetl-storage-side-credential-hygiene/round-02-result.md`)
— its "Round B Kickoff List" is the surface map this round
implements.

## Why this round exists

PR #604 (Round A) added a worker-side scrub that strips the
`keychain` namespace from the result before persistence and
event emission. That scrub handles the *structured top-level
result*. It does **not** automatically handle the **derived
artifacts** the worker generates from that result, and it does
**not** govern data the worker pushes through other surfaces:

1. **Result store previews / extracted fields.** The worker
   computes previews and `extracted` snapshots from tool
   results. If a tool returns a payload with embedded
   credential material outside the explicit keychain namespace
   (e.g. an Authorization header in an HTTP response), the
   preview / extract carries it forward.
2. **Transient variables.** `noetl/worker/transient.py` stores
   arbitrary variable values keyed by execution. Round A
   doesn't intercept this path.
3. **Caller-provided result API writes** at
   `noetl/server/api/result/endpoint.py:124-161`. The endpoint
   accepts arbitrary JSON and writes it to the shared store.
4. **Caller-provided temp API writes** at
   `noetl/server/api/temp/endpoint.py:86-120`. Same shape.
5. **Arrow IPC payloads** at
   `noetl/core/storage/result_store.py:370-430`. Opaque bytes;
   can't be scrubbed after serialization. Producer-side
   schema-awareness is required.

The read-side redaction from PR #603 stays in place as the
final safety net. Round B is the **producer-side** defense
across those five surfaces.

## What this round delivers

1. **Extend `noetl/core/credential_refs.py`** (the helper
   PR #604 added) with:
   - A producer-side scrub function that accepts a payload
     and a context map (which keychain namespaces the caller
     knows are in scope), returns a scrubbed copy.
   - Detection patterns for common header-shaped credential
     material (Authorization headers, X-API-Key, cookies),
     reusing patterns from
     `redact_keychain_values()` where possible to avoid
     drift.
2. **Patch the five producer surfaces:**
   - `noetl/worker/result_handler.py` — scrub before preview
     generation and before storing extracted fields.
   - `noetl/worker/transient.py` — scrub before persisting
     `var_value`.
   - `noetl/server/api/result/endpoint.py` POST paths — scrub
     incoming caller-provided payloads at the write boundary.
   - `noetl/server/api/temp/endpoint.py` POST paths — same.
   - `noetl/core/storage/result_store.py` Arrow IPC writes —
     producer-side schema-aware policy (see Phase B for the
     design decision).
3. **Tests** covering each producer:
   - Unit: scrub function handles tool-result-shaped payloads
     with embedded credential material.
   - Integration: synthetic execution generates a result
     containing an HTTP response with an Authorization header
     → assert the preview, extracted field, and persisted
     result row carry redaction, the tool itself still sees
     cleartext.
   - Unit on each endpoint POST: incoming payload with a
     credential-shaped field is scrubbed before write.
4. **Live verification** on GKE (pre-authorized) — synthetic
   execution that hits all five producer paths; query the
   database directly; confirm no cleartext.
5. **Wiki update** per Rule 1b — extend the existing
   `secrets-and-redaction` page with the producer-side
   surfaces + the schema-aware policy for Arrow IPC.
6. **One PR on `noetl/noetl`** (draft, do not merge).
7. **Result file** at
   `handoffs/active/2026-05-26-noetl-credential-refs-round-b/round-01-result.md`.

## Phases

### Phase A — sync + scope confirmation

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only origin main
   git -C repos/noetl-wiki fetch origin && git -C repos/noetl-wiki checkout master && git -C repos/noetl-wiki pull --ff-only origin master
   ```
   `repos/noetl` should include `c26b0460 chore(release):
   version 2.100.7` (PR #604 + release tag). If it does not,
   stop — Round A has not landed yet.

2. Re-read the round-02 result of the storage-side-hygiene
   thread (archived). Confirm its "Round B Kickoff List"
   matches the five surfaces above. If codex sees additional
   producer surfaces in the current code, surface them in
   the audit and decide per-surface whether to fold them in
   or defer.

### Phase B — design decisions

3. Branch `repos/noetl`:
   ```
   git -C repos/noetl checkout -b kadyapam/credential-refs-round-b
   ```

4. **Decide the Arrow IPC strategy.** Three viable shapes;
   pick one and document the choice in the result:

   - **(i) Producer-side scrub before serialization.** Every
     call site that produces an Arrow IPC payload first
     scrubs the source dict / record-batch keys against the
     known keychain namespaces. Simplest; relies on
     producers being good citizens.
   - **(ii) Declared-schema-only writes.** Arrow IPC writes
     require the producer to declare a payload schema; the
     storage layer refuses writes whose columns include
     known credential patterns. Higher invariant; bigger
     surface change.
   - **(iii) Best-effort post-serialization redaction.**
     Decode the IPC on read, redact on output. Pushed to
     read-side; doesn't actually fix the storage leak. Not
     acceptable as the primary defense; only if (i) is not
     reachable for some producer.

   Preference: **(i)** for this round. Document if any
   producer needs (ii) treatment as a follow-up.

5. **Decide the API-endpoint policy** for
   `/api/result/*` and `/api/temp/*` POST writes:
   - The caller is the noetl worker (internal HTTP). Treat
     this as a defense-in-depth gate: apply the scrub helper
     on incoming payloads before write.
   - The endpoints do not gain a new schema requirement.
     Callers continue to send opaque payloads; the endpoint
     just scrubs.

6. **Confirm the scope of header-pattern detection.**
   Round A's `redact_keychain_values` already covers
   Authorization/Bearer/Basic/JWT shapes. Round B should
   *re-use* those patterns rather than re-implementing.
   The Round B helper imports or composes Round A's.

### Phase C — implement

7. **Extend `noetl/core/credential_refs.py`** with the
   producer-side scrub function described in item 1.
   Compose it with `redact_keychain_values` from Round A
   for header-pattern detection.

8. **Patch the five producer surfaces** per item 2. Each
   patch site must:
   - Apply the scrub at the producer boundary, never inside
     the tool execution itself (the tool must still see
     cleartext).
   - Preserve the existing return / write semantics
     (signature, error envelopes).
   - Add a one-line code comment pointing to the
     `agents/rules/execution-model.md` secrets-and-credentials
     rule.

9. **Do not modify** the existing PR #603 read-side
   redaction or PR #604's Round A worker dispatch scrub.
   They stay; this round adds new producer-side coverage.

10. **Do not modify** the keychain reference shape
    (`$noetl_ref`). The wire format stays.

### Phase D — tests

11. Add tests per item 3. Aim for one focused unit test per
    producer + one integration test that exercises all five
    paths in one execution.

12. Run the noetl test suite. Document new failures and any
    pre-existing failures that overlap with the changed
    surface. The travel `extract_turn` integration test
    added in Round A should still pass.

### Phase E — live validation

13. Pre-authorized: build the new image (Cloud Build), helm
    upgrade against the GKE cluster:
    ```
    helm upgrade --reuse-values --set image.tag=<tag>
    ```
    The live cluster currently runs Helm rev 160 with the
    Round A image; this round bumps it forward.

14. Register a temporary playbook that:
    - Calls an HTTP tool returning a response with an
      Authorization header (simulated; use a fixture).
    - Stores transient variables.
    - Triggers the worker to write a result with both
      preview and extracted fields.
    - Optionally writes an Arrow IPC payload.

15. Query the database directly (no value dumps; use
    pattern-count queries as in Round A's validation):
    - `select * from noetl.result_store_blobs where execution_id = <id>`
      and inspect previews / extracted columns.
    - `select * from noetl.transient_var where execution_id = <id>`.
    - `select * from noetl.result_metadata` for the Arrow
      rows.
    - Run pattern-count queries for known credential shapes.
    - All counts: `0`.

16. Confirm the tool itself succeeded (proves the scrub
    only operates on the producer-side boundary, not on
    the tool input).

### Phase F — wiki update

17. Extend `repos/noetl-wiki/`'s secrets-and-redaction page
    (currently at `aad9b64`) with:
    - The five producer-side surfaces and the scrub helper.
    - The Arrow IPC policy (whichever option Phase B
      chose).
    - The API endpoint defense-in-depth model.
    - Cross-link to PR #603 (read-side) and PR #604
      (Round A) for the complete picture.

18. Update `Home.md` / `_Sidebar.md` if structure changed.

19. Commit + push the wiki:
    ```
    git -C repos/noetl-wiki add -A
    git -C repos/noetl-wiki commit -m "wiki(security): producer-side credential scrub (Round B)"
    git -C repos/noetl-wiki push origin master
    ```

### Phase G — open PR + write result

20. Commit + push noetl:
    ```
    git -C repos/noetl add -A
    git -C repos/noetl commit -m "fix(security): producer-side credential scrub for result/temp/transient/Arrow IPC (Round B)"
    git -C repos/noetl push -u origin kadyapam/credential-refs-round-b
    ```

21. Open draft PR with `gh pr create --repo noetl/noetl`.
    Body must cover:
    - Why (link the two predecessor PRs + their wiki page).
    - The five producer surfaces patched.
    - The Arrow IPC strategy chosen + rationale.
    - The defense-in-depth model with PR #603 / PR #604.
    - Live verification summary with placeholder
      redactions.
    - Wiki link.

22. Write
    `handoffs/active/2026-05-26-noetl-credential-refs-round-b/round-01-result.md`.

    Required sections:
    ```
    ## Phase A — sync
    ## Phase B — design decisions
    ## Phase C — implementation
    ## Phase D — tests
    ## Phase E — live validation
    ## Phase F — wiki update
    ## Issues observed
    ## Manual escalation needed
    ```

23. Commit + push the result.

## Hard rules for this thread

- **Do not merge the PR.** Open as draft, link, stop.
- **Never include leaked values themselves** in any file
  under ai-meta or in any wiki, PR body, or commit message.
  Use placeholders. The ai-meta repo is public.
- **Do not retroactively rewrite historical rows.** The
  event log is immutable. Old data stays where it is and
  relies on PR #603's read-side redaction.
- **Do not remove or weaken PR #603 or PR #604.** Both stay.
- **Do not modify the `$noetl_ref` wire format.** It is
  contract.
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision`.**
- **No "canonical"** in any commit message, PR body, doc,
  or prose. See `agents/rules/writing-style.md`.
- **Live cluster operations are pre-authorized this round**
  for the patched-image build, helm upgrade, and DB-side
  verification queries. No other shared-state changes
  pre-authorized.
- **Wiki update is mandatory (Rule 1b).** Round B is not
  complete without Phase F.
- **If implementation reveals a sixth producer surface or
  forces a Round-A change**, stop and write the result with
  `status: blocked` rather than expanding scope. Open a
  follow-up round.

## What success looks like

- `redact_keychain_values` + the new producer scrub close
  the producer-side leak across all five surfaces.
- New executions write redacted previews / extracted fields
  / transient vars; Arrow IPC payloads carry no credential
  material.
- Tool execution itself still sees cleartext at dispatch.
- Live cluster proves it with `0` pattern hits across the
  changed surfaces.
- Draft PR open on `noetl/noetl`.
- noetl-wiki page extended.
- Result file written and pushed.

## Out of scope (separate handoffs)

- Read-side redaction changes (PR #603 territory).
- Storage-side reference shape changes (PR #604 territory).
- `/api/executions?limit=N` listings stale-status bug
  (separate handoff queued).
- Platform-side per-step event batching (separate handoff
  queued).
- Backfilling historical rows (event log is immutable).
