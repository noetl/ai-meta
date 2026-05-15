---
name: handoff-result
description: Scaffold the result file for a cross-agent handoff (executor side). Finds the latest round-NN-prompt.md under a thread and creates the matching round-NN-result.md from the template.
argument-hint: "<slug>"
allowed-tools:
  - Bash
  - Read
  - Write
---

# Scaffold a Handoff Result

The executor (typically Codex, but any agent) uses this skill to
create the result file the dispatcher is waiting on.

Full convention: `handoffs/README.md`.
Behavioral rules: `agents/rules/handoffs.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug>`. Confirm
   `handoffs/active/<slug>/` exists. If not, abort and tell the user
   to check the slug.
2. Locate the highest-numbered `round-NN-prompt.md` under the thread:

   ```bash
   ls handoffs/active/<slug>/round-*-prompt.md | sort | tail -n1
   ```

3. Read the prompt's frontmatter. Capture:
   - `thread:`     — the full slug.
   - `round:`      — the round number `NN`.
   - `from:`       — who wrote the prompt (will become `to:` in the
                     result).
   - `expects_result_at:` — the result filename to create (default
                            `round-NN-result.md`).
   - `wait_phrase:` (optional) — note it so the executor can respect
                                 the gate.
4. Confirm the expected result file does NOT already exist. If it
   does, abort — never overwrite a prior result. Open a new round
   instead (next prompt + next result).
5. Read `handoffs/templates/result.md`.
6. Write the result file at the expected path with frontmatter:
   - `thread:`       → from prompt.
   - `round:`        → from prompt.
   - `from:`         → the current agent's name (e.g. `codex`).
   - `to:`           → the prompt's `from:`.
   - `created:`      → current UTC time in ISO 8601.
   - `in_reply_to:`  → the prompt filename you read in step 2.
   - `status:`       → `partial` as a placeholder. The agent updates
                       this when filling in the body.
7. Print to the user, in this exact shape:

   ```
   Scaffolded handoffs/active/<slug>/round-NN-result.md

   Now fill in the body. One H2 per phase the prompt declared, plus:
     ## Issues observed
     ## Manual escalation needed

   When done, update frontmatter `status:` to one of:
     complete | partial | blocked

   Then commit:
     git add handoffs/active/<slug>/round-NN-result.md
     git commit -m "handoff(result): <slug> round NN"
   ```

8. Do NOT commit automatically. The result body must be filled in
   first.

## Hard constraints

- Never overwrite an existing result file.
- Never include secrets in the result body.
- Match the prompt's phase structure exactly so the dispatcher can
  diff/grep.
- If a gated phase was correctly skipped, record
  `phase X blocked: awaiting <wait_phrase>` rather than omitting it.
- This skill writes a single file; it does not push, does not open
  PRs, does not call other agents.
