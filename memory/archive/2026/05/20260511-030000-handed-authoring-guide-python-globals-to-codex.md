# Handed authoring-guide python-globals rule to Codex (13th rule from the travel arc)

- date: 2026-05-11T03:00:00Z
- tags: docs, playbook-authoring-guide, python-globals, retro-rule, codex-handoff

## Round goal

Pin the NoETL Python globals/locals idiom as the 13th rule in
`repos/docs/docs/reference/playbook_authoring_guide.md`.

The lesson: NoETL executes `kind: python` step code with separate globals
and locals dicts. Helper functions defined at the top of a step's code body
are visible to top-level statements but NOT to OTHER helper functions via
closure unless explicitly republished via `globals().update({...})`.

## Why it deserves a rule

The footgun has bitten THREE rounds in the travel arc:

1. Phase 3 vertex-ai merger — caught and patched in-flight
2. Hotels/activities classifier extension — patched as ops#62
3. Phase 4 ollama playbook — handled cleanly because prior rounds taught us

It's also baked into the existing `automation/agents/mcp/vertex-ai.yaml`
playbook (lines 224-239 are exactly this pattern). Three rediscoveries in
five days is the cost of NOT having a rule. The 13th rule pays it down.

## Where it fits

Existing 12 rules sit in 6 sections (after the workload-defaults rule
landed in docs#52). The new rule is about kind:python step authoring —
not keychain, not workload, not step semantics, not external HTTP, not
YAML/SQL quoting, not GUI. Best fit: a new `## Python step authoring`
section inserted between `## External HTTP calls` and `## YAML and SQL
quoting` (loosely, the new section sits between HTTP-as-tool and
YAML-quoting concerns — both of which are also about what you write at
specific layers of the playbook).

## The rule

Title: **Republish helpers through globals before calling them from other helpers**

Good:
```python
def _helper_one():
    return _helper_two() + 1

def _helper_two():
    return 42

globals().update({
    '_helper_one': _helper_one,
    '_helper_two': _helper_two,
})

result = {'value': _helper_one()}
```

Bad: same code without the `globals().update({...})` block — NameError at
runtime when _helper_one calls _helper_two.

Why: NoETL passes the user's `code` string to a runner that calls
`exec(code, globals_dict, locals_dict)` with two separate maps. Top-level
statements write to locals; function definitions resolve free variables
against globals at call time. Imports auto-publish to globals; user
functions don't.

## Phases (3)

1. Apply edit (single-section insertion); verify docs build clean.
2. Docs PR.
3. Bump repos/docs gitlink in ai-meta. Stage but do not push.

## Bridge artefacts

- `bridge/inbox/delegated/20260511-030000-authoring-guide-python-globals.task.json`
- `scripts/authoring_guide_python_globals_msg.txt`

## What's next after this lands

9. Single-source-of-truth refactor for the classifier system_prompt
   (the "load-bearing" debt from Phase 4)
10. Anthropic re-smoke (gated on user)
11. (NEW from item #7) Activities NoETL-reference hydration bug — child
    result stored as reference, parent doesn't hydrate; affects all agent
    → MCP hops with large payloads, not travel-specific. Lives in
    repos/noetl. Out of "ops + docs" scope; will need a separate noetl
    repo round.

After #9 and #10, the architectural arc has no obvious next round. The
travel agent is feature-complete. Item #11 is a distinct noetl-engine
follow-up.
