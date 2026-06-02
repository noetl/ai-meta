---
thread: 2026-05-28-noetl-worker-keychain-resolver-fix
round: 1
from: claude
to: codex
created: 2026-05-28T15:00:00Z
status: open
expects_result_at: round-01-result.md
tracks: noetl/ai-meta#24
wait_phrase: "ship keychain resolver fix"
---

# Worker keychain resolver — fix the $noetl_ref encoding/decoding for python-tool inputs

> **Tracks:** [noetl/ai-meta#24](https://github.com/noetl/ai-meta/issues/24)
> — Worker doesn't re-read rotated credentials — keychain resolver
> bypasses noetl.credential fallback.
>
> The trail this issue captures has narrowed to one concrete bug
> after a partial fix landed in noetl/ops#125. This round delivers
> the noetl/noetl PR that unblocks credential resolution at the
> worker layer end-to-end. Once it lands, Duffel works
> (noetl/ai-meta#21 closes) and any future credential-backed MCP
> works without per-playbook special casing.

## What we know works (verified on GKE this morning)

1. **Credential row** at `noetl.credential` for `duffel_token` is
   present and decryptable. `GET /api/credentials/duffel_token?include_data=true`
   returns the right token value (verified directly: prefix
   `duffel_test_aTmITR...`, 55 chars).
2. **Token works against Duffel directly** — the same value via
   `curl https://api.duffel.com/air/airlines?limit=2` returns
   airline rows (`12 North`, `40-Mile Air`).
3. **`process_keychain_section`** in
   `noetl/server/keychain_processor.py` now correctly resolves the
   duffel playbook's keychain entry — `kind: credential_ref` was
   added in noetl/ops#125. The server logs
   `Cached secret keychain: duffel_token for catalog <N> (scope: global, ...)`.
4. **`noetl.keychain` cache row** lands correctly with the right
   data. `GET /api/keychain/<catalog_id>/duffel_token?scope_type=global`
   returns the resolved token value verbatim (verified directly).

## What's broken

5. **The worker's python-tool dispatch never reads the cache row.**
   Every smoke execution of `catalog://automation/agents/mcp/duffel`
   still ends with `Duffel get_airlines failed: access_token_not_found`
   despite (1)–(4) all being correct.
6. **`noetl.keychain.access_count` stays at 0** after the failing
   dispatch — proving the worker doesn't call
   `GET /api/keychain/{catalog_id}/duffel_token` for this exec.
7. **Worker logs show no `[KEYCHAIN]` or `KEYCHAIN: Found N
   references` info-log lines** for the failing dispatch.
   `populate_keychain_context` exits early via
   `has_keychain_ref(task_config) → False` in
   `noetl/worker/keychain_resolver.py:408`.
8. **The python tool sends `Authorization: Bearer ` (empty)** to
   Duffel — confirmed by the Duffel-side error shape
   (`access_token_not_found` is what Duffel returns when no token
   is in the Bearer slot).

## Likely root cause (hypothesis to verify)

The playbook step has:

```yaml
- step: duffel_dispatch
  tool:
    kind: python
    input:
      ...
      duffel_token: "{{ keychain.duffel_token.token }}"
    code: |
      ...
      headers={"Authorization": f"Bearer {duffel_token}", ...}
```

The server side renders `tool.input` BEFORE the keychain values
are loaded into the render context. The Jinja template
`{{ keychain.duffel_token.token }}` evaluates against an empty
`keychain` dict and produces `""` (empty string). By the time the
worker receives the command, the `tool.input` is already
pre-rendered; the worker's
`populate_keychain_context` scanner finds no `keychain.*`
references in `task_config` (because they're already gone) and
returns early. The python tool then runs with `duffel_token = ""`
and Duffel rightly rejects.

`noetl/core/credential_refs.py` has the **right primitive** for this
problem — `keychain_ref(name, field)` produces a JSON placeholder
of shape `{"$noetl_ref": {"kind": "keychain", "name": ..., "field": ...}}`
that survives JSON serialization, and `_resolve_value` /
`resolve_credential_references` know how to substitute them
against a resolved keychain dict at the worker side.

Either:

- (A) `{{ keychain.* }}` Jinja templates are supposed to be
  rewritten into `$noetl_ref` placeholders at playbook load /
  command issuance, and that rewrite step isn't firing for
  python-tool `tool.input` blocks; **or**
- (B) The server has all the data it needs at command-issuance
  time but is rendering templates against an empty keychain
  context (the manifest tracks names + field hints but not
  values, and values live in `noetl.keychain` which the server
  doesn't read before rendering).

The fix is one of:

- Rewrite the Jinja-to-`$noetl_ref` step so it fires for
  `tool.input` blocks regardless of tool kind (the working amadeus
  playbook may slip through because its `keychain.amadeus_token.access_token`
  reference happens to be resolved on the workflow-state side
  rather than the tool-input side — verify this).
- Or: have the server populate `context["keychain"]` with the
  resolved values from `noetl.keychain` immediately after
  `process_keychain_section` and before rendering any tool input,
  so subsequent `{{ keychain.* }}` templates render to the right
  values inline.
- Or: have the worker keep a copy of `_keychain_manifest` and
  re-render the tool input on its side using values pulled from
  the keychain endpoint.

This is a design call — pick whichever is most consistent with
the existing intent of noetl/noetl#603 ("persist keychain refs for
worker dispatch") which added 233 lines to `credential_refs.py`
and touched lifecycle.py / commands.py / state.py / transitions.py
/ nats_worker.py. Read that PR's diff first — the answer is
likely in there.

## Where to operate

- `repos/noetl` only. Branch off `main`:
  `kadyapam/worker-keychain-resolver-fix`.

## Phases

### Phase A0 — sanity checks (no remote writes)

1. `git submodule status repos/noetl` should show no `+` / `-`
   prefix; if it does, `git submodule sync --recursive && git
   submodule update --init --recursive` from ai-meta root.
2. Read these files end-to-end (they're the call graph the bug
   lives in):
   - `repos/noetl/noetl/core/credential_refs.py` — the
     placeholder primitive (`keychain_ref`, `is_keychain_ref`,
     `parse_pure_keychain_expression`, `encode_keychain_templates`,
     `resolve_credential_references`, `_resolve_value`).
   - `repos/noetl/noetl/server/keychain_processor.py` — the
     `process_keychain_section` that fires at execution start
     and writes `noetl.keychain` rows.
   - `repos/noetl/noetl/server/api/keychain/endpoint.py` +
     `service.py` — the GET endpoint the worker calls.
   - `repos/noetl/noetl/worker/keychain_resolver.py` — the
     `populate_keychain_context` + `resolve_keychain_entries`.
   - `repos/noetl/noetl/worker/nats_worker.py:2475–2570` — where
     the worker calls `populate_keychain_context` +
     `resolve_credential_references` and then renders the tool
     input.
   - `repos/noetl/noetl/core/dsl/engine/executor/commands.py`,
     `lifecycle.py`, `state.py`, `transitions.py` — server-side
     command issuance (these were touched by PR #603).
   - `repos/noetl/noetl/tools/python/executor.py:600–660` —
     where the python tool renders `args` against `context`.
3. **Read PR #603** (`fix(security): persist keychain refs for
   worker dispatch`, commit SHA `862303d8`, 2026-05-25). It's the
   most recent intentional design change in this area; the bug
   is most likely a gap in what that PR delivered.

### Phase A1 — confirm the failure shape (no remote writes)

4. Capture proof of the bug shape against the deployed GKE
   environment:
   - Re-confirm the keychain endpoint serves the right value:
     ```
     curl -sS https://gateway.mestumre.dev/noetl/keychain/636776086033924192/duffel_token?scope_type=global \
       -H "Authorization: Bearer $GATEWAY_TOKEN"
     ```
     (Get `$GATEWAY_TOKEN` from `~/.noetl/config.yaml`'s
     `contexts.gke-prod.gateway_session_token` field — the file is
     YAML, the field is unquoted.)
   - Run a fresh duffel smoke and grab the new execution_id:
     ```
     noetl --context gke-prod exec \
       catalog://automation/agents/mcp/duffel --runtime distributed \
       --payload '{"method":"tools/call","tool":"get_airlines","arguments":{"limit":5}}' \
       --json
     ```
   - Pull the events: `GET /noetl/executions/<exec>/events`.
     Confirm:
     - `command.completed` for `duffel_dispatch` has
       `status_code: 401`, error string
       `access_token_not_found`.
     - The `command.issued` event's `context.render_context.ctx`
       does NOT contain a `duffel_token` field; `_keychain_manifest`
       is `[REDACTED]` (response-boundary masking) but the field
       names should appear in the manifest entries.
5. Check the worker logs for that exec to confirm
   `[KEYCHAIN]` and `KEYCHAIN: Found N references` are missing
   (or DEBUG-filtered):
   ```
   kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster -n noetl \
     logs -l app=noetl-worker --since=5m --tail=3000 \
     | grep -E "<exec_id>|KEYCHAIN"
   ```
6. Capture the cache row's `access_count` before AND after the
   exec — confirm it stays at 0 (worker didn't query the cache):
   ```
   curl -sS https://gateway.mestumre.dev/noetl/postgres/execute \
     -H "Authorization: Bearer $GATEWAY_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"query":"SELECT cache_key, access_count, accessed_at FROM noetl.keychain WHERE keychain_name = '"'"'duffel_token'"'"'","database":"noetl"}'
   ```

### Phase A2 — write the fix (no remote writes)

7. Decide between fix paths (A) / (B) / (C) above. The decision
   should reference what PR #603 was aiming for — if it was
   aiming at (A) but missed the python-tool path, completing (A)
   is the right call. If it was aiming at (B), audit why the
   server's render context is empty.
8. Implement the fix in `repos/noetl`. Keep the diff minimal —
   don't refactor adjacent code while you're in there.
9. Add unit tests:
   - The Jinja-to-`$noetl_ref` rewrite covers `tool.input`
     blocks for python tools (not just workflow-state-side
     references).
   - The worker's `populate_keychain_context` /
     `resolve_credential_references` actually substitutes values
     into the rendered input.
   - Both shapes of credential — `kind: credential_ref` (the
     duffel pattern) and `kind: oauth2` (the amadeus pattern) —
     resolve correctly through the same path.
10. The existing test `repos/noetl/tests/core/test_credential_refs.py`
    is the right home for the rewrite tests; the worker side may
    need a new file under `repos/noetl/tests/worker/`.

### Phase A3 — local verification (no remote writes)

11. Run the existing noetl test suite:
    `cd repos/noetl && pytest -x tests/ 2>&1 | tail -30`.
    Capture exit code + last 30 lines in the report.
12. If a local kind cluster is available, run the duffel smoke
    against it. Skip cleanly if not — note "no local kind
    available; defer to Phase A5 gated GKE smoke" in the report.

### Phase A4 — commit (no remote writes)

13. From `repos/noetl`:
    ```
    git checkout -b kadyapam/worker-keychain-resolver-fix
    git add <touched files>
    git -c commit.gpgsign=false commit -m "$(cat <<EOF
    fix(worker): resolve {{ keychain.* }} templates in python-tool tool.input

    The keychain manifest produced by process_keychain_section
    tracked which entries existed but did NOT populate render
    context with their values before the server rendered
    tool.input blocks for command issuance.  Jinja templates
    like {{ keychain.duffel_token.token }} therefore rendered
    to empty string, the worker received pre-rendered command
    input with no keychain refs to scan, populate_keychain_context
    short-circuited via has_keychain_ref → False, and the
    python tool sent Authorization: Bearer to upstream APIs.

    Diagnostic captured in noetl/ai-meta#24 and the smoking
    gun was Duffel's access_token_not_found 401 on the new
    catalog v12 (post noetl/ops#125 playbook fix).

    Refs noetl/ai-meta#24
    Refs noetl/ai-meta#21
    EOF
    )"
    ```
    Adjust the commit body to match the actual fix you wrote.
14. Do NOT push. The dispatcher will green-light Phase A5 after
    reviewing the diff.

### Phase A5 — push + open PR

> ***Run only after explicit human go-ahead. Wait phrase: `ship keychain resolver fix`.***

15. `cd repos/noetl && git push -u origin kadyapam/worker-keychain-resolver-fix`
16. `gh pr create --repo noetl/noetl --base main --head kadyapam/worker-keychain-resolver-fix`
    Body cites noetl/ai-meta#24 + noetl/ai-meta#21 + handoff
    thread path. Test plan includes the GKE smoke commands from
    Phase A6.
17. Print the PR URL. Do NOT merge.

### Phase A6 — GKE smoke after merge + redeploy

> ***Run only after explicit human go-ahead. Wait phrase: `verify keychain fix on gke`.***

18. After the PR merges and a new noetl image is built +
    deployed to GKE (the dispatcher handles the Cloud Build +
    Helm rollout — do NOT run those yourself), run:
    ```
    noetl --context gke-prod exec \
      catalog://automation/agents/mcp/duffel --runtime distributed \
      --payload '{"method":"tools/call","tool":"get_airlines","arguments":{"limit":5}}' \
      --json
    ```
19. Pull the events; confirm `command.completed` for
    `duffel_dispatch` has `isError: false`, `status_code: 0` or
    `200`, and `control_data.data` is a non-empty list of
    airlines.
20. Confirm `noetl.keychain.access_count` for
    `duffel_token:<catalog_id>:global` incremented (proving the
    worker actually queried the cache this time).
21. Re-run the SPA "trip to paris" flow OR confirm via the
    travel SPA that the search_offers tool returns results
    instead of "I could not complete that search". If the SPA
    flow is still broken because of unrelated bugs (e.g.
    Round 2 of noetl/ai-meta#23 hasn't landed yet), note that
    explicitly — Phase A6 only validates the keychain path,
    not the full SPA chain.

## FINAL REPORT

Write `round-01-result.md` with frontmatter:

```yaml
---
thread: 2026-05-28-noetl-worker-keychain-resolver-fix
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Body — one H2 per phase + standard sections:

```markdown
## Phase A0 — sanity checks
- submodule status
- PR #603 summary (what it tried to deliver, what it left
  undelivered)
- read graph: which files map to which step in the credential
  resolution path

## Phase A1 — confirmed failure shape
- fresh execution_id + key event-log lines
- cache row state before/after exec (access_count proof)
- worker log evidence

## Phase A2 — fix
- diff summary (file:line, what changed, what stayed)
- rationale for fix path (A vs B vs C from prompt)
- test additions

## Phase A3 — local verification
- pytest results (exit code + last 30 lines)
- kind smoke if run; otherwise SKIPPED with reason

## Phase A4 — commit
- branch + SHA
- files in commit

## Phase A5 — push + PR
- COMPLETED / BLOCKED-awaiting-wait-phrase
- PR URL if completed

## Phase A6 — GKE smoke
- COMPLETED / BLOCKED-awaiting-wait-phrase
- execution_id + cache access_count proof if completed

## Issues observed
- bullet list. Grep-able fingerprints (error strings, status
  codes, stack frame top lines). No paraphrasing.

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
  especially `execution-model.md`, `issue-tracking.md`,
  `wiki-maintenance.md`, and `safety.md`.
- Do not store secrets in any file under ai-meta (the repo is
  public). Mask any token values you encounter while diagnosing
  (the duffel token in particular — its `duffel_test_aTmITR...`
  prefix is fine to reference; the full value is NOT).
- If a step's preconditions aren't met, stop and report — don't
  improvise around blockers.
- Do not modify `repos/ops/automation/agents/mcp/duffel.yaml`
  in this round — the playbook side is already fixed. The whole
  point of this PR is that the next credential rotation should
  work without per-playbook special casing.
- Do not modify `repos/travel/` in this round — that's the
  parallel Round 2 work on noetl/ai-meta#23.

## Open questions to address in the report

- **Why does amadeus work?** Amadeus uses the same Jinja
  template shape (`{{ keychain.amadeus_token.access_token }}`).
  Is it actually working today, or is it broken in the same
  way and nobody noticed because the SPA hasn't been hitting
  it recently? Verify by smoke-testing
  `catalog://automation/agents/mcp/amadeus tools/call search_locations`
  with a simple query and capturing the same event fields.
- **Was PR #603 supposed to fix this?** Read the PR
  description and commit body verbatim. Quote the relevant
  intent. If it was supposed to fix this and didn't, that's
  the gap this PR closes.
- **Does the fix also resolve noetl/ai-meta#20** (REDACTED
  NameError in google-places MCP dispatch)? Note any signal
  but do not pivot to that issue in this round.
