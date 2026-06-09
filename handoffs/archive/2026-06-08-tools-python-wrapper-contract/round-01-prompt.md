---
thread: 2026-06-08-tools-python-wrapper-contract
round: 1
from: claude
to: codex
created: 2026-06-08T05:15:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "ship it"
---

# noetl-tools python wrapper: inject `input_data` global + support top-level `return`

> **Predecessor:** [noetl/ai-meta#71](https://github.com/noetl/ai-meta/issues/71)
> — the ai-task issue this round closes. The cascade evidence on
> `loop_test.yaml` + `actions_test.yaml` + the
> `test_args_passing.yaml` false-pass lives in the issue body +
> comments. This handoff scopes the implementation.

You are porting two missing pieces of the legacy
`noetl/noetl/tools/python/executor.py` contract into the Rust
`noetl-tools` python tool wrapper.  Both pieces are mechanical and
self-contained inside `repos/tools/src/tools/python.rs`.  The
fixtures driving this work live in `repos/e2e/fixtures/playbooks/`
and have been authored against the legacy contract; the Rust
wrapper currently diverges from it.

## Background

- **Operating directory:** `/Volumes/X10/projects/noetl/ai-meta`.
- **Branch base:** repos/tools is on `main` at the noetl-tools
  v2.23.1 release commit.  Do NOT bump the crate version yet — that
  comes via release-please on merge.
- **Files in scope:**
  - `repos/tools/src/tools/python.rs` — the only `.rs` file you need
    to edit for the contract change.  The wrapper template is built
    inside `PythonTool::execute_code` (around line 458).
  - `repos/tools/src/tools/python.rs` unit tests at the bottom of the
    same file — add at least three new tests pinning the new shapes
    (see Phase B acceptance below).
- **Reference (legacy contract):**
  - `repos/noetl/noetl/tools/python/executor.py:578-680` — the exec
    setup with `exec_globals` injection.  Read lines 689-770 too
    for the `main()` convention parity.  Do NOT change Python
    files; this is a reference-only file.
- **Issue body to read first:**
  [noetl/ai-meta#71](https://github.com/noetl/ai-meta/issues/71)
  has the full failure traces, fixture pointers, and the design
  options.  Read the comment thread too — there's a follow-up
  comment that surfaces the `input_data` global gap.

### Current Rust wrapper shape (verbatim from python.rs around line 459)

```python
import sys
import json

context = json.loads(sys.stdin.read())
args = context.get('args', {})
variables = context.get('variables', {})
execution_id = context.get('execution_id')
step = context.get('step')

# Make args available as globals for convenience
globals().update(args)

# User code
{user_code_goes_here}

# Legacy `main()` convention — noetl/ai-meta#65 — already in
# place.  Calls main(**kwargs) when `result` is unset and
# `main` is callable.

# Emit the user-set `result` global as JSON on a single line
# prefixed with the noetl marker.
```

### Two gaps the Rust wrapper does not honor

1. **`input_data` global is not injected.**  The legacy Python
   wrapper exposes the step's input dict as `input_data` (and as
   `args`); the Rust wrapper exposes only `args` (spread via
   `globals().update(args)`).  Fixtures that call
   `input_data.get('foo')` fail with
   `NameError: name 'input_data' is not defined`.
   - Evidence: `actions_test.yaml` process_loop step
     `num = input_data.get('num')` → NameError.
   - The `test_args_passing.yaml` `use_vars` step has the same
     issue but the orchestrator-status-drift bug ([noetl/ai-meta#72](https://github.com/noetl/ai-meta/issues/72))
     masked it.
2. **Top-level `return X` is a SyntaxError.**  Fixtures use
   `return X` at the top of a `code: |` block as a shortcut for
   "set the result to X and stop".  Python rejects this with
   `SyntaxError: 'return' outside function` because the wrapper
   exec's user code at module level.
   - Evidence: `loop_test.yaml` start step
     `return {"number": num, ...}` → SyntaxError.
   - There are 7+ fixtures hitting this pattern (grep
     `^\s*return ` over `repos/e2e/fixtures/playbooks/*.yaml`).

The Rust wrapper already supports the **`main()` convention** from
[noetl/ai-meta#65](https://github.com/noetl/ai-meta/issues/65) — if
the user defines `def main(args, ...)`, the wrapper calls it and
captures the return value.  Top-level `return` is the missing
shape.

## Design contract for this round

Implement BOTH gaps in the wrapper.  The wrapper must support all
three styles concurrently — same user-facing semantics regardless
of which shape the fixture uses:

| Style | User code | Output capture |
| :-- | :-- | :-- |
| **A. result-global** | `result = {"x": 1}` at top level | `result` global captured (current shape) |
| **B. main-function** | `def main(args): return {"x": 1}` | `main(**kwargs)` called when `result` is unset (current shape, #65) |
| **C. top-level-return** | `return {"x": 1}` at top level | Wrap user code in implicit `def __noetl_step__(args, input_data, **kw): {user_code}` and call it; capture return value as `result` |

Implementation strategy for Style C:
- Detect top-level `return` via lightweight string check — `^\s*return ` in any line of `code:` (after stripping comments and string literals is overkill; a simple regex on raw lines is fine for the common case).  If found, wrap user code in:

  ```python
  def __noetl_step__(args, input_data, **kw):
  {indented user code}

  result = __noetl_step__(args, input_data)
  ```

  - Indent every user-code line by 4 spaces.
  - The implicit function gets `args` (current global dict) + `input_data` (same dict, exposed as a parameter so `return` works) + `**kw` for forward-compat.
- If no top-level `return` is found: keep the existing module-level
  exec shape so Styles A and B work unchanged.
- The `main()` convention (Style B) MUST still work alongside Style
  C — a fixture that uses `def main()` AND has no top-level `return`
  should go through the existing main() path, not the wrapped path.
- The `input_data` global injection applies to ALL styles
  uniformly: add `input_data = dict(args)` to the wrapper, after
  the `globals().update(args)` line.

### Why a string check is acceptable (vs full AST parse)

The fixture authors use `return X` deliberately as a top-level
shortcut.  Edge cases the string check might mis-fire on:
- `return` inside a `def`/`class` body — the string check WILL
  mis-flag this as top-level.  Mitigation: only trigger Style C
  wrap when NO `def `/`class ` precedes the first `return ` line.
- `# return X` in a comment — exclude lines starting with `#` from
  the check.

If the heuristic gets it wrong, the user code will syntax-fail
inside the wrapper — same as today.  The risk surface is small;
the implementation is one regex + one if-else.  Do NOT pull in a
full Python AST library (`rustpython-parser` etc.) for this round.

## Phases

### Phase A — read-only survey + design confirmation (unattended)

1. Read `repos/tools/src/tools/python.rs` end-to-end.  Capture in
   your final report:
   - Line number of the wrapper template format! macro.
   - Line numbers of the existing unit tests for `execute_code`.
   - Whether the existing main()-convention path needs any
     refactor to coexist with the new top-level-return path.
2. Re-read the legacy reference at
   `repos/noetl/noetl/tools/python/executor.py:578-770`.  Confirm
   that legacy's exec namespace includes `input_data` as a global
   key (search for `exec_globals['input_data']` or similar
   assignment).  Report what you find.
3. Walk the existing kind validation breadcrumbs from
   [noetl/ai-meta#71](https://github.com/noetl/ai-meta/issues/71):
   - Kind exec `322239728994750464` (loop_test) — top-level-return failure.
   - Kind exec `322240336095088640` (actions_test) — input_data NameError.
   - Kind exec `322228896269340672` (test_args_passing) — same as actions_test.

### Phase B — implement + test + clippy + release build (unattended)

> Run unattended.  No remote writes.  Commit locally on a feature branch.

4. Create branch `feat/python-wrapper-input-data-and-return-support`
   on `repos/tools` (off current `main`).
5. Edit `repos/tools/src/tools/python.rs`:
   - Add `input_data = dict(args)` to the wrapper template, right
     after the `globals().update(args)` line.  Keeps Styles A and
     B unchanged; lets every code path reference `input_data`.
   - Add Style C support: before substituting `{}` into the
     wrapper template, run the regex check on the user code; if
     top-level `return ` is detected (and no `def `/`class `
     precedes it), wrap the user code in
     `def __noetl_step__(args, input_data, **kw):` + indented
     body, then append `result = __noetl_step__(args, input_data)`.
   - Preserve the existing Style B `main()` convention check
     verbatim — it still applies for fixtures that define `def
     main()` without top-level `return`.
6. Add at least three new unit tests to the bottom of `python.rs`:
   - `test_input_data_global_is_injected` — code is
     `result = {"got": input_data.get("foo")}`, args is
     `{"foo": "bar"}`, assert ToolResult data has `got: "bar"`.
   - `test_top_level_return_wraps_user_code` — code is
     `return {"echoed": input_data.get("n", 0) * 2}`, args is
     `{"n": 5}`, assert ToolResult data has `echoed: 10`.
   - `test_top_level_return_with_no_input_data` — code is
     `return {"ok": True}`, args is `{}`, assert ToolResult data
     has `ok: true` (covers the no-args path).
   - Optional: `test_main_function_convention_still_works_with_input_data_global` — pins back-compat for Style B.
7. `cd repos/tools && cargo fmt && cargo build --release` — must be
   clean.
8. `cargo test --lib` — must pass entirely; record `<total> passed
   / 0 failed` count for your final report.
9. `cargo clippy --lib --tests --release -- -D warnings` — must be
   clean for `repos/tools` (the noetl/server clippy debt from #161
   does NOT apply here; tools should be lint-clean).
10. Commit locally with a `feat:` prefix message that cites
    `Closes noetl/ai-meta#71` in the body.  Stage all changes
    under `repos/tools` only.  Do NOT push.

### Phase C — push branch + open PR (gated on `ship it`)

> ***Run only after explicit human go-ahead. Wait phrase: `ship it`.***

11. `git push -u origin feat/python-wrapper-input-data-and-return-support`
    on `repos/tools`.
12. Open the PR via `gh pr create` with:
    - Title: `feat(python): inject input_data global + support top-level return`
    - Body citing `Closes noetl/ai-meta#71` in the footer.
    - Test plan section listing the three new unit tests + the
      kind re-val checklist (loop_test, actions_test,
      test_args_passing — those should COMPLETE with passing
      per-step status after the noetl-worker bumps to the new
      noetl-tools version).
13. Comment on noetl/ai-meta#71 with the PR URL.
14. **STOP.**  Do not bump the noetl-worker dep, do not bump
    pointers in ai-meta, do not roll the kind deployment.  Claude
    will own that follow-up once release-please tags the
    noetl-tools release.

## FINAL REPORT

Always emit this, even on early STOP.  Write it as the body of
`expects_result_at` with frontmatter:

```yaml
---
thread: 2026-06-08-tools-python-wrapper-contract
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then the report markdown:

```markdown
## Phase A — read-only survey
- Wrapper template line numbers...
- Legacy contract findings (input_data injection: yes/no/where)...
- Kind-val breadcrumbs surveyed.

## Phase B — implement + tests + build
- Files touched (just `repos/tools/src/tools/python.rs` expected).
- Diff summary (lines added/removed).
- Test count: `<N> passed / 0 failed` (was `<M>` pre-change).
- Release build outcome.
- Clippy outcome.
- Local commit SHA on `feat/python-wrapper-input-data-and-return-support`.

## Phase C — open PR
- Either: PR URL + comment URL.  OR: `Phase C blocked: awaiting ship it`.

## Issues observed
- Anything surprising.  Include real error strings / stack frame
  tops if anything failed.  Do NOT paraphrase.

## Manual escalation needed
- Claude (dispatcher) follow-ups after the PR merges:
  - Wait for release-please tag.
  - Bump noetl-worker dep to the new noetl-tools version.
  - Rebuild noetl-worker image, kind reload, re-run the three
    fixtures.
  - Bump ai-meta pointer + close noetl/ai-meta#71.
```

Then write the report and commit it with message
`handoff(result): 2026-06-08-tools-python-wrapper-contract round 01`.
Push the result file to origin/main on ai-meta — the result file
itself is public-safe per `agents/rules/handoffs.md`.  Do NOT push
the implementation branch on `repos/tools` until "ship it" is said.

## Hard rules for this thread

- Never push to `origin/main` on any repo.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`.
- Do NOT bump the noetl-tools version in `Cargo.toml` by hand —
  release-please owns versioning; a `feat:` commit prefix triggers
  the MINOR bump.
- Do NOT touch Python code.  The legacy executor.py is a
  reference-only file; only `repos/tools/src/tools/python.rs`
  changes in this round.
- Do not store secrets in any file under ai-meta (the repo is public).
- If a step's preconditions aren't met, stop and report — don't
  improvise around blockers.
