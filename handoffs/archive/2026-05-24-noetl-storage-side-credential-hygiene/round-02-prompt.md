---
thread: 2026-05-24-noetl-storage-side-credential-hygiene
round: 2
from: claude
to: codex
created: 2026-05-25T06:10:00Z
status: open
expects_result_at: round-02-result.md
---

# Round A — command + state safety + worker-side dispatch resolution

> **Predecessors in this thread:**
> - `round-01-prompt.md`: opened the storage-side scope.
> - `round-01-result.md` (status: `partial`): the audit revealed
>   the work is bigger than one safe round. Codex stopped after
>   Phase A/B per the prompt's gate and proposed splitting the
>   implementation into a **Round A** (command/state safety) and
>   a **Round B** (result/temp/transient/Arrow producer-side
>   hardening). The user accepted that split.
>
> This round implements **Round A**.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose), and
`agents/rules/wiki-maintenance.md` (Rule 1b — wiki rides with
the pointer bump).

Also re-read round-01-result.md (in this same thread directory).
It contains the audit table and the design that this round
implements. The design is approved as-is; do not re-litigate
the reference shape or resolution timing.

## What this round implements (Round A only)

Scope is **strictly**:

1. New helper module **`noetl/core/credential_refs.py`** with:
   - Recursive detection of keychain templates (`{{ keychain.X.Y }}`
     and similar).
   - Encoder for pure keychain expressions to the
     reference shape:
     ```json
     {"$noetl_ref": {"kind": "keychain", "name": "<entry>", "field": "<field_or_null>"}}
     ```
   - Detection of mixed expressions (templates that combine a
     keychain reference with other text or other Jinja). These
     must be **deferred** — left as the original template string
     in storage; resolved at worker dispatch.
   - Worker-side resolver that takes the in-memory step input,
     walks the structure, resolves every `$noetl_ref` and every
     keychain template, returns the resolved structure with
     cleartext.

2. **Stop the server-side keychain leak** at the source:
   - `noetl/server/keychain_processor.py` continues to write
     resolved keychain entries into `noetl.keychain` (this is
     the supported storage for credential material). **It must
     not return resolved values to the lifecycle for
     `state.variables` injection.**
   - `noetl/core/dsl/engine/executor/lifecycle.py:164-175`
     (the keychain-injection block identified in round-01)
     must not populate `state.variables` (or
     `state.variables.keychain`) with resolved values. The
     workflow keeps a per-execution **manifest of available
     keychain entries** (names + field hints, no values) so
     downstream rendering can encode references.
   - The `playbook.initialized` and `workflow.initialized`
     event payloads must not carry resolved keychain values.
     Workload snapshots in those payloads carry references or
     placeholders.

3. **Server command rendering changes** in
   `noetl/core/dsl/engine/executor/commands.py:972-1021`:
   - When server-side rendering encounters a **pure keychain
     expression**, encode it as a `$noetl_ref` instead of
     resolving to cleartext.
   - When it encounters a **mixed expression** containing a
     keychain reference, leave the original template string in
     place (deferred to worker dispatch).
   - Strip `keychain` (and any equivalent resolved-credential
     namespace) from the rendered `render_context` before
     command persistence.

4. **Worker dispatch resolves references** just before invoking
   the tool:
   - `noetl/worker/nats_worker.py:1908-2024` (or wherever the
     just-before-tool-execution render context is assembled)
     calls the new resolver from
     `noetl/core/credential_refs.py` on the step's input and
     tool config. Cleartext lives only in the in-memory context
     handed to the tool; it never goes back into emitted event
     payloads.
   - After the tool returns, the worker must **scrub** any
     resolved keychain namespace from the result before it
     hits `result_handler` / event emission.

5. **Tests** covering the Round A surface only:
   - Unit: `credential_refs.encode` and `credential_refs.resolve`
     round-trip pure and mixed expressions correctly.
   - Unit: `process_keychain_section` no longer causes resolved
     values to appear in `ExecutionState.variables`.
   - Unit: pure keychain expression is stored as `$noetl_ref` in
     `command.context`. Mixed expression is stored as the
     original template string.
   - Integration: synthetic execution of a playbook step that
     uses `{{ keychain.foo.api_key }}` — assert
     `noetl.event.context`, `noetl.command.context`, and
     `noetl.execution.state` contain references / placeholders
     for that execution.
   - Worker integration: synthetic dispatch — assert the tool
     receives cleartext, the emitted `step.exit` / `call.done`
     events do not.

6. **Live validation** on the GKE cluster (pre-authorized this
   round):
   - Build and push the new image.
   - `helm upgrade --reuse-values --set image.tag=<tag>`.
   - Register a temporary travel-style playbook that uses
     `{{ keychain.openai_token.api_key | default('') }}`
     (the `extract_turn` shape from round-01).
   - Run 3–5 turns.
   - Query directly:
     ```
     select state from noetl.execution where execution_id = <id>;
     select context, result from noetl.event where execution_id = <id> limit 20;
     select context from noetl.command where execution_id = <id> limit 20;
     ```
   - **Assert no cleartext** keychain values. Use placeholder
     redactions in any output captured to the result file.
   - Confirm the actual LLM call inside the worker still
     succeeded (proves worker-side resolution functioned).

7. **Wiki update** per Rule 1b:
   - Extend `repos/noetl-wiki/secrets-and-redaction.md` (or
     whichever slug currently covers the topic — codex
     verifies). Document:
     - The `$noetl_ref` shape (kind / name / field).
     - The pure-vs-mixed expression handling rule.
     - The resolution timing (worker dispatch).
     - The retained read-side redaction as a safety net.
     - That result/temp/Arrow producer-side hardening is **Round
       B**, tracked but not in this PR.

8. **One PR on `noetl/noetl`** (draft, do not merge).

9. **Result file** at
   `handoffs/active/2026-05-24-noetl-storage-side-credential-hygiene/round-02-result.md`.

## What this round explicitly does NOT do (Round B scope)

Codex flagged in round-01 that the following surfaces are
storage seams but **cannot** be safely fixed by Round A's
pattern (server-side render + worker-dispatch resolution). They
need producer-side / schema-aware approaches and are out of
scope for this round:

- `noetl/worker/result_handler.py` previews + extracted fields.
- `noetl/core/storage/result_store.py` (result / temp tier
  writes, including Arrow IPC payloads).
- `noetl/worker/transient.py:420-456` transient var writes.
- `noetl/server/api/result/endpoint.py` and
  `noetl/server/api/temp/endpoint.py` accepting arbitrary
  caller-provided data.

Touch any of these only to **add a scrub step at the worker
result boundary** (item 4 above — strip the keychain namespace
from worker result before it crosses any of these surfaces).
The producer-side hardening of each surface remains Round B.

If during implementation you find Round A leaks bleed into any
Round-B surface, document it in "Issues observed" and stop;
do not widen the change.

## Phases

### Phase A — sync

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only origin main
   git -C repos/noetl-wiki fetch origin && git -C repos/noetl-wiki checkout master && git -C repos/noetl-wiki pull --ff-only origin master
   ```
2. Confirm `repos/noetl` includes PR #603 (the read-side
   redaction) — the round-02 changes layer on top, do not
   remove that fix.
3. Re-read round-01-result.md. The audit table in Phase A of
   that result is the surface map for this round.

### Phase B — implementation

4. Branch `repos/noetl`:
   ```
   git -C repos/noetl checkout -b kadyapam/storage-side-credential-hygiene-round-a
   ```
5. Add `noetl/core/credential_refs.py` per item 1 above.
6. Modify `keychain_processor.py` and `lifecycle.py` per
   item 2.
7. Modify `commands.py` rendering per item 3.
8. Modify `nats_worker.py` dispatch per item 4. Add the
   result-scrub step (strip `keychain` namespace from result
   before any persistence call).
9. **Do not modify** any file listed under "What this round
   explicitly does NOT do" beyond the worker result-scrub
   step. If a code path forces a wider change, stop and write
   the result with `status: blocked`.

### Phase C — tests

10. Add the unit + integration tests per item 5.
11. Run the noetl test suite (focused first, then full where
    feasible). Document new failures or pre-existing failures
    that overlap with the changed surface.

### Phase D — live validation

12. Build + helm upgrade per item 6.
13. Run the synthetic turns. Capture before/after database
    queries with **placeholder redactions** — never paste
    real keychain or token values into the result.
14. Confirm the LLM-backed step succeeded (worker-side
    resolution worked).
15. If any DB-side query still surfaces cleartext for the new
    execution, file the gap as a blocker and stop before
    Phase E/F.

### Phase E — wiki update

16. Extend the wiki page per item 7.
17. Update `Home.md` / `_Sidebar.md` if structure changed.
18. Commit + push the wiki:
    ```
    git -C repos/noetl-wiki add -A
    git -C repos/noetl-wiki commit -m "wiki(security): storage-side persistence — references not cleartext (Round A)"
    git -C repos/noetl-wiki push origin master
    ```

### Phase F — open PR + write result

19. Commit + push the noetl branch:
    ```
    git -C repos/noetl add -A
    git -C repos/noetl commit -m "fix(security): persist keychain references; worker-side dispatch resolution (Round A)"
    git -C repos/noetl push -u origin kadyapam/storage-side-credential-hygiene-round-a
    ```
20. Open draft PR with `gh pr create --repo noetl/noetl`.
    Body must cover:
    - Why (link round-01-result.md design section).
    - The `$noetl_ref` shape and the pure-vs-mixed rule.
    - Helper module + integration points.
    - Storage seams patched in this round.
    - **What was intentionally not patched and why** (the
      Round B list).
    - Live verification summary with placeholder redactions.
    - Wiki link.
21. Write
    `handoffs/active/2026-05-24-noetl-storage-side-credential-hygiene/round-02-result.md`.

    Required sections:
    ```
    ## Phase A — sync
    ## Phase B — implementation
    ## Phase C — tests
    ## Phase D — live validation
    ## Phase E — wiki update
    ## Issues observed
    ## Manual escalation needed (Round B kickoff list)
    ```

22. Commit + push the result.

## Hard rules for this thread

- **Do not merge the PR.** Open as draft, link, stop.
- **Never include the leaked values themselves** in any file
  under ai-meta or in any wiki, PR body, or commit message.
  Use placeholders. The ai-meta repo is public.
- **Do not retroactively rewrite event-log rows.** The event
  log is immutable.
- **Do not remove or weaken the read-side redaction from PR #603.**
  It is the safety net.
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- **Live cluster operations are pre-authorized this round**
  for the patched-image build, helm upgrade, and DB-side
  verification queries. Do not pre-authorize anything else.
- **Wiki update is mandatory** (Rule 1b). Round-02 is not
  complete without Phase E.
- **Stay within Round A scope.** If a code path forces
  widening into Round B, document the conflict in "Issues
  observed" and file the round as `partial` rather than
  expanding.

## What success looks like

- New executions write `$noetl_ref` (or deferred templates) to
  `noetl.execution.state`, `noetl.event.context`, and
  `noetl.command.context`. No cleartext keychain values appear
  in those rows for a fresh execution.
- The actual tool call inside the worker still receives
  cleartext and the LLM-backed step still succeeds.
- Old data unchanged; PR #603 redaction still effective.
- Draft PR open on `noetl/noetl`.
- Wiki updated.
- Result file written and pushed.

## Round B kickoff hints (for the next round, not this one)

- Result store previews / extracted fields.
- Result/temp API endpoints accepting arbitrary caller data
  (provenance problem — possibly out-of-scope unless we add a
  declared "may contain credentials" header).
- Arrow IPC producer-side schema-aware policy.
- Transient variable writes.
- Worker debug logs that include resolved keychain data (code
  is adjacent; consider rolling into Round B or doing as a
  small interim fix).

Open the Round-B prompt only after Round A merges and lives
quiet in production for a stretch.
