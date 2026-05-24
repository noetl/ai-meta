---
thread: 2026-05-24-noetl-keychain-leak-redaction
round: 1
from: claude
to: codex
created: 2026-05-24T20:25:00Z
status: open
expects_result_at: round-01-result.md
---

# Audit + redact resolved keychain values from noetl-server endpoints

> **Predecessor:**
> `handoffs/active/2026-05-24-travel-itinerary-planner-consolidation/round-01-result.md`
> issue #3:
>
> > "`noetl status --json` includes resolved keychain values in
> > `variables`. I avoided copying those values into PRs, wiki
> > pages, and this result, but the status endpoint itself should
> > be reviewed for redaction."
>
> This handoff scopes and lands the redaction work.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose), and
`agents/rules/wiki-maintenance.md` (especially Rule 1b — wiki
updates ride with any submodule pointer bump) before starting.

## Why this round exists

Codex's audit of the itinerary-planner consolidation run
surfaced that the noetl-server status endpoint (`GET
/api/executions/{execution_id}/status`, exercised by
`noetl status --json` against the CLI) returns resolved
keychain values in the `variables` field of the response.
Keychain entries like `{{ keychain.openai_token.api_key }}`
that the workflow uses internally are appearing in HTTP
responses with their resolved cleartext values.

Codex avoided propagating any of those values into the PR,
wiki, or handoff result they wrote. But the leak is live on
the GKE cluster today, and operators using
`noetl status --json` can read tokens they should never see.

There is precedent for output-side redaction in this codebase:
`redact_url_credentials()` in
[`repos/noetl/noetl/core/sanitize.py`](https://github.com/noetl/noetl/blob/main/noetl/core/sanitize.py)
was added in noetl/noetl#601 for the same class of bug in
log lines. This handoff applies the same posture to HTTP
responses.

## What this round delivers

1. **An audit report** of which endpoints surface variables /
   payloads that could contain resolved keychain values.
   Inventory every endpoint, every field, every event-log
   row shape where the leak can appear.
2. **A redaction helper** (extending or paralleling
   `redact_url_credentials`) that masks resolved keychain
   values when serializing responses. The helper must be
   easy to apply at every leak site identified in the audit.
3. **Wired-in redaction** at every leak site. Responses to
   `GET /api/executions/{id}/status`, `/api/executions/{id}`,
   `/api/executions/{id}/events`, `/api/vars/{id}`, and any
   other endpoint the audit surfaces, no longer expose
   resolved keychain cleartext.
4. **Test coverage** that pins the new behavior: a unit
   test per redaction helper, and an integration-style test
   that exercises an execution with a keychain-referenced
   variable and asserts the response is masked.
5. **Live verification** on the GKE cluster (pre-authorized
   below) against an existing execution that has the leak
   today.
6. **Wiki updates** per Rule 1b:
   - `repos/noetl-wiki/` — add or extend a page covering
     credentials/secrets handling in the noetl runtime;
     document the redaction contract.
   - Cross-link from `agents/rules/execution-model.md`'s
     secrets-and-credentials rule.
7. **One PR on `noetl/noetl`** (do not merge).
8. **Result file** at
   `handoffs/active/2026-05-24-noetl-keychain-leak-redaction/round-01-result.md`.

## Background

### Where the leak likely originates

The workflow runtime resolves Jinja references like
`{{ keychain.openai_token.api_key }}` at step-execution time.
If the resolved value is stored back into a per-execution
`variables` map (rather than only consumed transiently by the
tool), every subsequent serialization of that map — to a
client, to the event log, to the response of `status` —
exposes it.

Two fixes are possible:

- **Output-side redaction** (this round's scope): pattern-
  match resolved values against the keychain at serialization
  time and mask them. Minimum viable; ships now.
- **Storage-side hygiene** (future round): never persist
  resolved values; persist only the reference, resolve at
  every use. Larger refactor; touches the workflow runtime's
  variable resolution path.

Codex picks the output-side path this round. Flag any
storage-side concern in "Issues observed" but don't widen
the change.

### Reference precedent

PR `noetl/noetl#601` shipped `redact_url_credentials()` in
[`noetl/core/sanitize.py`](https://github.com/noetl/noetl/blob/main/noetl/core/sanitize.py)
to mask `user:password@` patterns in NATS / Postgres / HTTP
URLs in log lines. Pattern reuse: a new helper
`redact_keychain_values()` in the same module, called from the
same kinds of serialization seams.

### What I observed during the 2026-05-24 incident triage

When I queried `/api/executions/633632330480877738/status`
during the auth-login triage, the `variables` field included
`auth0_token: "<full Auth0 ID token>"`. That's a real bearer
credential (the user's Auth0 ID token from the SPA login
flow). The same response shape surfaces keychain-resolved
tokens for OpenAI, Anthropic, Duffel, Amadeus, and any
other third-party API the playbooks use.

The audit needs to consider:

- User-bearer tokens (Auth0 ID token, etc.) passed in as
  workload.
- Keychain-resolved values (`{{ keychain.X.Y }}`).
- Any secret-shaped value that ended up in a variables map
  by way of intermediate step output.

Codex's helper should redact all three classes, not only
"things that came from the keychain."

## Phases

### Phase A — sync + audit (read-only)

1. Sync submodules:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only origin main
   git -C repos/noetl-wiki fetch origin && git -C repos/noetl-wiki checkout master && git -C repos/noetl-wiki pull --ff-only origin master
   ```
2. Survey every endpoint that surfaces `variables` or
   serialized payload data. Start with `noetl/server/api/` in
   the noetl repo. Inventory:
   - `GET /api/executions/{id}` (full detail)
   - `GET /api/executions/{id}/status`
   - `GET /api/executions/{id}/events`
   - `GET /api/vars/{id}` and `GET /api/vars/{id}/{var_name}`
   - `GET /api/api/result/*` family
   - `GET /api/api/temp/*` family
   - GraphQL `executePlaybook` response (the gateway
     forwards this; the redaction happens server-side).
   - Anything else the audit finds.
3. Inventory storage shapes:
   - Where `variables` lives in Postgres
     (`noetl.workflow_state` / `noetl.event` /
     `noetl.execution`).
   - What fields can hold resolved values.
   - Whether resolved values are persisted, or only computed
     transiently.
4. Inventory existing redaction code:
   - `noetl/core/sanitize.py` (the precedent helper).
   - Any other `_redact*` / `_sanitize*` / `_mask*`
     functions in `noetl/`.
5. Identify the actual leak surface on a live execution.
   Pick a recent itinerary-planner execution from GKE,
   query `/api/executions/{id}/status`, and record (with
   redaction in the result file — do **not** copy the
   plaintext values verbatim) which keys carry secrets.
   Use placeholder labels in the result, e.g.
   `variables.auth0_token = <REDACTED-IN-REPORT>`. The
   point is to enumerate the keys, not the values.

### Phase B — design + helper

6. Branch `repos/noetl`:
   ```
   git -C repos/noetl checkout -b kadyapam/keychain-redaction
   ```
7. Add `redact_keychain_values()` (or pick a clearer name) in
   `noetl/core/sanitize.py`. Contract:
   - Accepts a dict (or arbitrary nested structure) and the
     set of "secret-bearing" key patterns + values to mask.
   - Returns the same structure with secret values replaced
     by a constant placeholder
     (`REDACTED = "<redacted>"` or similar; match the
     precedent used by `redact_url_credentials`).
   - Idempotent: running it twice changes nothing.
   - Handles nested dicts, lists of dicts, and value-only
     leaks (no key needed) when the value matches a known
     pattern (e.g. JWT structure `eyJ.*\..*\..*`).
   - Test-covered with a parametrized unit suite, including
     the three leak classes (user-bearer, keychain-resolved,
     secret-shaped intermediate).
8. Decide the **detection strategy**. Two options to
   consider:
   - **Key-based:** redact values whose key matches a
     well-known pattern (`*token*`, `*secret*`,
     `*api_key*`, `*password*`, `auth0_id_token`,
     `auth0_token`, `auth0_refresh_token`, etc.).
   - **Value-based:** redact values whose shape matches a
     known secret pattern (JWT, OAuth bearer, AWS keys,
     etc.).
   The robust answer is **both**, with a clear precedence
   order. Codex picks and documents the choice.

### Phase C — wire in redaction at every leak site

9. For every endpoint identified in Phase A's audit, apply
   the redaction helper at the serialization boundary.
   Prefer a single FastAPI response middleware / model
   serializer if the framework supports it; otherwise wrap
   each endpoint's response with the helper.
10. Be careful not to redact the **stored** data. The
    redaction is a serialization concern, not a storage
    concern. The event log and `workflow_state` keep the
    resolved values (today) so the workflow runtime can
    function; this round only changes what crosses the HTTP
    boundary. (A follow-up round can address storage-side
    hygiene.)
11. Update existing tests that exercise these endpoints to
    assert the redacted output. Add new tests where
    coverage is missing.
12. Run the full noetl test suite:
    ```
    cd repos/noetl
    pytest tests/  # or whatever the noetl test invocation is
    ```
    All must pass.

### Phase D — live validation

13. Pre-authorized cluster operation: re-query the live
    cluster's status endpoint for an execution known to have
    the leak today, after the patched noetl-server is
    deployed. Steps:
    - Build the new noetl image (Cloud Build).
    - `helm upgrade --reuse-values --set image.tag=<new-tag>`
      against the GKE cluster.
    - `kubectl rollout status deploy/noetl-server -n noetl
      --timeout=180s`.
    - Re-run the same query that demonstrated the leak.
    - Assert all secret-bearing values are now `<redacted>`.
14. Capture the before/after response shape in the result
    (still with values themselves redacted to placeholder).
15. **If the patched response still leaks anywhere**, do
    NOT proceed to wiki or PR — file the gap as a blocker
    and stop.

### Phase E — wiki update (mandatory per Rule 1b)

16. `repos/noetl-wiki/`: add or extend a page covering
    secrets handling. Suggested slug if creating new:
    `secrets-and-redaction`. Cover:
    - The keychain (existing surface; reference whatever the
      noetl wiki already says).
    - The new `redact_keychain_values()` helper: what it
      does, what classes of secrets it catches, where it is
      applied.
    - The serialization-boundary policy: stored vs surfaced.
    - Operator-facing checklist: what to expect when
      running `noetl status --json` against an execution
      that uses keychain references.
    - Cross-link to
      `agents/rules/execution-model.md`'s
      secrets-and-credentials rule and the
      [Ephemeral Blueprints](https://github.com/noetl/docs/blob/main/docs/architecture/ephemeral_blueprints.md)
      doc.
17. Update `repos/noetl-wiki/Home.md` and `_Sidebar.md`
    to surface the new (or updated) page.
18. Commit + push the wiki:
    ```
    git -C repos/noetl-wiki add <files>
    git -C repos/noetl-wiki commit -m "wiki(security): document keychain redaction"
    git -C repos/noetl-wiki push origin master
    ```

### Phase F — open PR + write result

19. Commit the noetl changes + push:
    ```
    git -C repos/noetl add -A
    git -C repos/noetl commit -m "fix(security): redact resolved keychain values from HTTP responses"
    git -C repos/noetl push -u origin kadyapam/keychain-redaction
    ```
20. Open the PR with `gh pr create --repo noetl/noetl`. Body
    must cover:
    - The leak (high-level — no values).
    - The detection strategy chosen (key + value, with
      examples of each).
    - The list of endpoints patched.
    - Live verification step.
    - Cross-link to the noetl wiki page in Phase E.
    - Note that storage-side hygiene (don't persist resolved
      values at all) is intentionally out of scope and
      tracked separately.
    - Use **draft PR** state. The user marks it ready when
      satisfied.

21. Write
    `handoffs/active/2026-05-24-noetl-keychain-leak-redaction/round-01-result.md`.

    Required sections:
    ```
    ## Phase A — audit
    ## Phase B — helper + detection strategy
    ## Phase C — endpoints patched
    ## Phase D — live validation
    ## Phase E — wiki update
    ## Issues observed
    ## Manual escalation needed
    ```

    Include:
    - Audit table: endpoint → field → leak class observed.
    - Detection-strategy decision + rationale.
    - PR URL + noetl-wiki commit SHA.
    - Before/after response excerpts (with placeholder
      values).
    - Test counts.

22. Commit + push the result in `ai-meta`.

## Hard rules for this thread

- **Do not merge the PR.** Open it as draft, link it, stop.
- **Never include the leaked values themselves** in any file
  under ai-meta or in any wiki, in any PR body, in any
  commit message. Use placeholders. The repo is public.
- **Never include the leaked values in the PR body either.**
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- **Live cluster operations are pre-authorized this round**
  for the patched noetl-server image upgrade and the
  before/after verification query. Do not pre-authorize
  anything else.
- **Wiki update is mandatory**, not optional. See
  `agents/rules/wiki-maintenance.md` Rule 1b. If you cannot
  reach Phase E, file the round as `partial` with a clear
  blocker.
- **Storage-side hygiene is explicitly out of scope.** Do not
  change how values are persisted in `workflow_state` /
  `event` / Postgres. Only change what crosses the HTTP
  boundary. Flag storage concerns in "Issues observed" for a
  follow-up handoff.

## What success looks like

- Audit table identifies every endpoint that leaks.
- `redact_keychain_values()` helper lands in
  `noetl/core/sanitize.py` with unit coverage.
- Every leaking endpoint serializes redacted output.
- Live cluster shows redacted output for a real
  execution that previously leaked.
- noetl wiki page documents the new behavior.
- Draft PR on `noetl/noetl` open with no merge.
- Result file written, committed, pushed.

## Out of scope (for separate handoffs)

- Storage-side: never persisting resolved values in the
  workflow runtime / event log.
- Platform-side per-step event batching (separate handoff
  already designed).
- `/api/executions` listings stale-status bug (separate
  handoff already designed).
- Gateway-side redaction of forwarded responses (the
  gateway is a proxy; if noetl-server returns redacted
  responses, the gateway forwards what it gets).
