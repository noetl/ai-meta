---
thread: 2026-05-28-noetl-worker-keychain-resolver-fix
round: 1
from: codex
to: claude
created: 2026-05-28T10:30:00Z
in_reply_to: round-01-prompt.md
status: partial
---

# Worker keychain resolver — $noetl_ref fix result

## Phase A0 — sanity checks

**Submodule status:** Clean at `47ea402f`. No `+` / `-` prefix. No sync needed.

**PR #603 summary** (commit `862303d8`, "fix(security): persist keychain refs for worker dispatch"):

The PR was clearly aiming at Fix Path A — convert Jinja keychain templates
to `$noetl_ref` placeholder dicts at command-issuance time so they survive
JSON serialization, then resolve them on the worker side by calling the
keychain endpoint. It delivered:

- `commands.py`: replaced `recursive_render(tool_config)` with
  `render_preserving_keychain_refs(env, tool_config, context, recursive_render)`
  which converts pure `{{ keychain.name.field }}` templates to
  `{"$noetl_ref": {"kind": "keychain", "name": ..., "field": ...}}` dicts.
- `commands.py`: `strip_keychain_namespaces(context, ...)` to scrub resolved
  values from render_context before it's sent to the worker.
- `state.py`: same strip call for context_vars; skips `keychain` key in context
  spreading.
- `nats_worker.py`: added `resolve_credential_references(...)` call after
  `populate_keychain_context(...)`.

**What it left undelivered:** The `has_keychain_ref` guard inside
`populate_keychain_context` was never updated to recognise the new
`$noetl_ref` dict shape. It only checks for `'keychain.'` substrings in
strings. So when a command arrives with `tool.input["duffel_token"] = {"$noetl_ref": {...}}`
the guard returns `False`, the function exits early, and `resolve_keychain_entries`
is never called. `resolve_credential_references` IS called afterward but
it also needs `context["keychain"]` to be populated first, and that population
depends on `populate_keychain_context` running successfully.

Similarly `extract_keychain_references_from_dict` only scanned string values
for `{{ keychain.* }}` regex — it did not detect `$noetl_ref` dicts either.

**Read graph — credential resolution call chain:**

```
Execution start (server)
  lifecycle.py: start_execution
    → keychain_processor.py: process_keychain_section
        reads playbook.keychain[].kind
        for kind=credential_ref → _process_credential_ref → noetl.credential → noetl.keychain
        returns _keychain_manifest (names + field hints; NO resolved values)
        manifest stored in state.variables[KEYCHAIN_MANIFEST_KEY]

Command issuance (server)
  commands.py: create_command
    → render_preserving_keychain_refs(env, tool_config, context, ...)
        context at this point has catalog_id + execution_id but keychain namespace is EMPTY
        (state.py: get_render_context explicitly skips "keychain" key)
        pure {{ keychain.X.field }} → {"$noetl_ref": {"kind":"keychain","name":"X","field":"field"}}
    → strip_keychain_namespaces(context, ...) → render_context sent to worker has no keychain values

Worker dispatch (worker)
  nats_worker.py: _execute_tool
    → populate_keychain_context(task_config_combined, context, catalog_id, ...)
        [BUG] has_keychain_ref({..., "$noetl_ref": {...}}) → False  ← early exit here
        extract_keychain_references_from_dict never called
        resolve_keychain_entries never called
        context["keychain"] never populated
    → resolve_credential_references({"config": config, "args": args}, context, ...)
        extract_keychain_ref_names does detect $noetl_ref correctly
        BUT _resolve_value(value, context, ...) looks up context["keychain"][name][field]
        context["keychain"] is absent → KeyError / empty → unresolved

Python tool injection (worker)
  python/executor.py
    args["duffel_token"] = {"$noetl_ref": {...}}  (unresolved dict)
    injected as-is into exec_globals["duffel_token"]
    f"Bearer {duffel_token}" → "Bearer {'$noetl_ref': ...}"  (or empty if str coercion)
    → Duffel API returns access_token_not_found 401
```

## Phase A1 — confirmed failure shape

**SKIPPED — no GKE access in this agent session.**

No `$GATEWAY_TOKEN` is available. kubectl context `gke_noetl-demo-19700101_us-central1_noetl-cluster`
is not configured for this session. Bash tooling was also blocked for this phase.

The failure shape is instead confirmed analytically from the read graph above and
the code evidence noted under A0. The four facts documented in the prompt (credential row
present, token valid, server-side cache row correct, access_count stays 0, worker logs
show no `[KEYCHAIN]` lines) are consistent with exactly the early-exit path traced above.

## Phase A2 — fix

**Decision: Fix Path A — extend `$noetl_ref` detection to the worker-side scanner.**

PR #603 introduced `render_preserving_keychain_refs` precisely to produce `$noetl_ref`
placeholders. The right completion is to make the worker's scanner recognize that shape
rather than changing the server-side flow (Fix B would require server reads of
`noetl.keychain` at command issuance — that's an additional DB hit per command and goes
against the design that keeps the worker's keychain endpoint as the authoritative
resolution point).

**Files changed:**

`repos/noetl/noetl/worker/keychain_resolver.py`

1. `extract_keychain_references_from_dict` (was ~line 183, function-level):
   - Added detection of `$noetl_ref` dicts before the recursive dict scan.
   - Shape checked: `data.get("$noetl_ref")` is a dict with `kind == "keychain"`.
   - Extracts `name`, returns early after adding to `refs` (no further recursion into the ref).
   - String path still calls `extract_keychain_references(data)` for Jinja templates.
   - Docstring updated to document both wire formats.

2. `has_keychain_ref` (local helper inside `populate_keychain_context`, ~line 405):
   - Added `$noetl_ref` detection at the top of the `isinstance(obj, dict)` branch:
     ```python
     noetl_ref = obj.get("$noetl_ref")
     if isinstance(noetl_ref, dict) and noetl_ref.get("kind") == "keychain":
         return True
     ```
   - This prevents the early-exit guard from firing when the command contains
     `{"$noetl_ref": {"kind": "keychain", ...}}` values in tool.input.

No other files were changed. The diff is intentionally minimal — the fix adds
~10 lines total, no refactoring of adjacent logic.

**Test additions:**

New file: `repos/noetl/tests/worker/test_keychain_resolver.py`

- `TestExtractKeychainReferencesFromDict` (10 tests):
  - `test_jinja_string_top_level` — Jinja template string still detected.
  - `test_noetl_ref_dict_top_level` — `$noetl_ref` at top dict level detected.
  - `test_noetl_ref_dict_nested` — `$noetl_ref` nested inside outer dict detected.
  - `test_mixed_jinja_and_noetl_ref` — both formats in same structure yield both names.
  - `test_noetl_ref_in_list` — `$noetl_ref` inside a list detected.
  - `test_non_keychain_noetl_ref_ignored` — `kind != "keychain"` not extracted.
  - `test_empty_dict_returns_empty_set` — empty dict returns empty set.
  - `test_plain_string_no_keychain_returns_empty` — plain string no match.
  - `test_noetl_ref_without_name_returns_empty` — `$noetl_ref` missing `name` → empty.
  - `test_credential_ref_kind` / `test_deeply_nested_noetl_ref` — edge cases.

- `TestPopulateKeychainContextNoetlRef` (4 tests):
  - `test_noetl_ref_in_input_triggers_resolution` — the primary regression test.
    Passes a `$noetl_ref` dict in `task_config["input"]`, monkeypatches
    `resolve_keychain_entries`, asserts it IS called (was never called before fix)
    and that `context["keychain"]` is populated correctly.
  - `test_jinja_string_still_triggers_resolution` — regression guard for the
    original Jinja-template path.
  - `test_no_keychain_ref_skips_resolution` — ensures no-ref config still skips resolver.
  - `test_oauth2_amadeus_noetl_ref` — amadeus-style `$noetl_ref` also resolves.

## Phase A3 — local verification

**BLOCKED — Bash tooling unavailable in this agent session.**

pytest could not be run. The required command is:

```
cd repos/noetl && python -m pytest tests/worker/test_keychain_resolver.py -v
```

And the broader regression suite:

```
cd repos/noetl && python -m pytest -x tests/ 2>&1 | tail -30
```

No local kind cluster was attempted.

Manual escalation: the dispatcher must run pytest before authorising Phase A5.

## Phase A4 — commit

**BLOCKED — Bash tooling unavailable in this agent session.**

The branch and commit could not be created. Required commands:

```bash
cd repos/noetl
git checkout -b kadyapam/worker-keychain-resolver-fix
git add noetl/worker/keychain_resolver.py tests/worker/test_keychain_resolver.py
git -c commit.gpgsign=false commit -m "$(cat <<'EOF'
fix(worker): detect \$noetl_ref placeholders in populate_keychain_context

render_preserving_keychain_refs (added in 862303d8) converts pure
{{ keychain.name.field }} Jinja templates to \$noetl_ref placeholder
dicts before the command is serialised for NATS dispatch.  The worker's
has_keychain_ref guard inside populate_keychain_context only checked for
the 'keychain.' substring in strings — it did not recognise the
\$noetl_ref dict shape.  Result: guard returned False for any tool.input
that contained a \$noetl_ref, populate_keychain_context exited early,
resolve_keychain_entries was never called, context["keychain"] was never
populated, and the python tool ran with unresolved placeholder dicts
injected as the credential variable.  Duffel received
Authorization: Bearer <dict> and returned access_token_not_found 401.

Fix:
- extract_keychain_references_from_dict: detect \$noetl_ref dicts
  (kind=keychain) in addition to {{ keychain.* }} regex patterns.
- has_keychain_ref (local to populate_keychain_context): return True
  when a dict has \$noetl_ref.kind == "keychain".

Both Jinja-template and \$noetl_ref wire formats now go through
resolve_keychain_entries and correctly populate context["keychain"]
before tool execution.

Refs noetl/ai-meta#24
Refs noetl/ai-meta#21
EOF
)"
```

## Phase A5 — push + PR

BLOCKED — awaiting wait phrase `ship keychain resolver fix`.

Also blocked by A3 and A4 not being run yet.

## Phase A6 — GKE smoke

BLOCKED — awaiting wait phrase `verify keychain fix on gke`.

## Open questions addressed

### Why does amadeus work?

Almost certainly it does NOT work — it is broken in the same way.
The amadeus playbook uses `{{ keychain.amadeus_token.access_token }}` in
`tool.input`, which `render_preserving_keychain_refs` converts to a
`$noetl_ref` dict. The same `has_keychain_ref → False` early exit fires.

The prompt notes "the working amadeus playbook may slip through because its
reference happens to be resolved on the workflow-state side rather than the
tool-input side." This is plausible only if the amadeus token was used in a
DSL `assign` or `condition` step (not in `tool.input`) — in that case the
Jinja template would be rendered against a context that had the keychain
manifest populated before reaching the worker.

Smoke-testing `catalog://automation/agents/mcp/amadeus tools/call search_locations`
was not possible in this session (no GKE access). Add it to Phase A6 verification.

### Was PR #603 supposed to fix this?

Yes. The commit message was "fix(security): persist keychain refs for worker
dispatch" and the PR added `render_preserving_keychain_refs` in `commands.py`
and `resolve_credential_references` in `nats_worker.py` with the exact
intent of carrying keychain refs from server to worker without persisting
resolved values in the event log.

The gap: the `has_keychain_ref` guard in `keychain_resolver.py:populate_keychain_context`
and `extract_keychain_references_from_dict` were not updated to recognise the
new `$noetl_ref` shape that PR #603 introduced. Both functions are in
`keychain_resolver.py`, which PR #603 did not touch — it only modified
`commands.py`, `state.py`, and `nats_worker.py`.

This PR closes that gap.

### Does the fix resolve noetl/ai-meta#20 (REDACTED NameError)?

Issue #20 is a NameError in google-places MCP dispatch. If the google-places
playbook also uses `{{ keychain.* }}` in a python tool's `input` block,
the same fix applies. However #20's error is a `NameError` (undefined variable),
not an auth 401 — the unresolved `$noetl_ref` dict injected into exec_globals
could produce a NameError if the tool code references it before type-checking.
Signal: possibly yes for the same root cause if google-places has a keychain
`input` block. Not investigated further in this round; do not pivot.

## Issues observed

- `has_keychain_ref({'$noetl_ref': {'kind': 'keychain', 'name': 'duffel_token', 'field': 'token'}})` returned `False` before fix — guard checked `'keychain.' in k` for dict keys (key is `'$noetl_ref'`, no match) and `'keychain.' in v` for string values (value is a dict, skipped) — early-exit triggered unconditionally for all `$noetl_ref` inputs.
- `extract_keychain_references_from_dict` only called `extract_keychain_references(data)` for `str` values — `$noetl_ref` dicts fell through the dict branch without yielding a name — `keychain_refs` set was empty — `resolve_keychain_entries` was never called even if the early-exit guard was bypassed.
- PR #603 touched `nats_worker.py` but not `keychain_resolver.py` — the two detection helpers in the resolver were not updated to recognise the new placeholder shape.
- Bash tooling blocked in this session — pytest and git commands could not be executed. Phases A3 and A4 require manual execution by the dispatcher.

## Manual escalation needed

The dispatcher must run the following before Phase A5:

**A3 — pytest (in `repos/noetl`):**
```bash
python -m pytest tests/worker/test_keychain_resolver.py -v
python -m pytest -x tests/ 2>&1 | tail -30
```

**A4 — create branch + commit (in `repos/noetl`):**
```bash
git checkout -b kadyapam/worker-keychain-resolver-fix
git add noetl/worker/keychain_resolver.py tests/worker/test_keychain_resolver.py
git -c commit.gpgsign=false commit -m "fix(worker): detect \$noetl_ref placeholders in populate_keychain_context

render_preserving_keychain_refs (added in 862303d8) converts pure
{{ keychain.name.field }} Jinja templates to \$noetl_ref placeholder
dicts before the command is serialised for NATS dispatch.  The worker's
has_keychain_ref guard inside populate_keychain_context only checked for
the 'keychain.' substring in strings — it did not recognise the
\$noetl_ref dict shape.  Result: guard returned False for any tool.input
that contained a \$noetl_ref, populate_keychain_context exited early,
resolve_keychain_entries was never called, context[\"keychain\"] was never
populated, and the python tool ran with unresolved placeholder dicts
injected as the credential variable.  Duffel received
Authorization: Bearer <dict> and returned access_token_not_found 401.

Fix:
- extract_keychain_references_from_dict: detect \$noetl_ref dicts
  (kind=keychain) in addition to {{ keychain.* }} regex patterns.
- has_keychain_ref (local to populate_keychain_context): return True
  when a dict has \$noetl_ref.kind == 'keychain'.

Both Jinja-template and \$noetl_ref wire formats now go through
resolve_keychain_entries and correctly populate context[\"keychain\"]
before tool execution.

Refs noetl/ai-meta#24
Refs noetl/ai-meta#21"
```

**A5 — push + PR (after wait phrase `ship keychain resolver fix`):**
```bash
git push -u origin kadyapam/worker-keychain-resolver-fix
gh pr create --repo noetl/noetl --base main --head kadyapam/worker-keychain-resolver-fix \
  --title "fix(worker): detect \$noetl_ref placeholders in populate_keychain_context" \
  --body "Closes the gap left by #603/#604. Refs noetl/ai-meta#24, noetl/ai-meta#21."
```
