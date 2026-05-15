---
name: handoff-open
description: Open a new cross-agent handoff thread (dispatcher side). Creates handoffs/active/<slug>/round-01-prompt.md from the template.
argument-hint: "<slug> \"<one-line description>\""
allowed-tools:
  - Bash
  - Read
  - Write
---

# Open a Handoff Thread

Create a new file-based handoff so the dispatcher (this agent) can pass
work to another agent (typically Codex) via a known path, and read the
report back from the matching `round-NN-result.md`.

Full convention: `handoffs/README.md`.
Behavioral rules: `agents/rules/handoffs.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug> "<description>"`. If the slug is
   missing the leading date prefix, prepend today's UTC date
   (`YYYY-MM-DD-`). Reject the input if the slug contains spaces or
   non-`a-z0-9-` characters.
2. Confirm `handoffs/active/<slug>/` does NOT already exist. If it
   does, abort and tell the user to either reuse the existing thread
   (next round) or pick a new slug.
3. `mkdir -p handoffs/active/<slug>/`.
4. Read `handoffs/templates/prompt.md`.
5. Write `handoffs/active/<slug>/round-01-prompt.md` from the
   template, replacing the `REPLACE-` tokens:
   - `thread:` → the full slug from step 1.
   - `created:` → current UTC time in ISO 8601 (e.g.
     `2026-05-15T22:00:00Z`).
   - Body title → the description from `$ARGUMENTS`.
6. Leave the prompt body as the template's scaffolded sections; this
   skill creates the file but does NOT fill in phases. The agent
   continues the conversation to flesh out the brief before committing.
7. Print to the user, in this exact shape:

   ```
   Created handoffs/active/<slug>/round-01-prompt.md

   Next:
     1. Edit the prompt body to add phases, gates, and the FINAL REPORT
        structure the executor must follow.
     2. Commit when ready:
          git add handoffs/active/<slug>/round-01-prompt.md
          git commit -m "handoff(open): <slug>"
     3. Tell the executor agent (e.g. Codex):
          You are operating in /Volumes/X10/projects/noetl/ai-meta.
          Read the handoff prompt at
            handoffs/active/<slug>/round-01-prompt.md
          end-to-end, follow handoffs/README.md, do the work, then
          write your report to
            handoffs/active/<slug>/round-01-result.md
   ```

8. Do NOT commit automatically. The dispatcher will commit once the
   prompt body is finished, since the template alone is not useful to
   the executor.

## Hard constraints

- Slug must be `<YYYY-MM-DD>-<lowercase-kebab-topic>`.
- Never overwrite an existing prompt or result file.
- Never include secrets in the prompt body.
- This skill writes a single file; it does not push, does not open
  PRs, does not call other agents.
