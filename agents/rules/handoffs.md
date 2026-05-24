# Cross-agent handoffs

This rule governs how AI agents operating in this repo (Claude Code,
Codex, Cursor, Gemini, and any future tool) pass work to each other
through files instead of chat.

Full convention: [`handoffs/README.md`](../../handoffs/README.md).

## When the convention applies

Use a file-based handoff whenever:

- A task spans multiple agent sessions (the receiver will not have
  the dispatcher's chat history).
- The dispatcher wants a structured report back at a known path.
- The work touches shared state (push, deploy, cancel, rerun) and
  needs explicit human gates.
- A future agent or teammate may need to pick up the thread.

For one-shot tasks that finish in a single chat ("rename this
variable", "explain this function"), stay in chat. Do not open a
handoff for trivial work.

## Paths to read and write

Threads live under `handoffs/active/<YYYY-MM-DD-slug>/`. Each round is
a pair:

```
handoffs/active/<slug>/round-NN-prompt.md     <-- dispatcher writes
handoffs/active/<slug>/round-NN-result.md     <-- executor writes
```

`NN` is zero-padded (`01`, `02`, …). The directory must sort in
chronological order on a vanilla `ls`.

Closed threads live under `handoffs/archive/<slug>/` with the same
contents, moved verbatim. Do not edit archived threads.

## Rules for the dispatcher (whoever writes a prompt)

1. **Scaffold from the template.** Copy `handoffs/templates/prompt.md`
   to `handoffs/active/<slug>/round-NN-prompt.md`. Replace every
   `REPLACE` token. Use `/handoff-open` if it is round 1.
2. **Self-contained brief.** The receiving agent will read no other
   chat history. Include every load-bearing path, branch name, SHA,
   command, and constraint inside the prompt body.
3. **Gate destructive phases.** Any phase that pushes, deploys,
   cancels an execution, or otherwise touches shared state must
   start with
   `*** Run only after explicit human go-ahead. Wait phrase: <phrase> ***`.
   Pure read-only or build-time verification phases run unattended.
4. **Declare the result path** in the prompt's frontmatter
   `expects_result_at` field. By default this is the matching
   `round-NN-result.md`.
5. **Commit when you write.** A prompt file is a public artifact; it
   goes into git history as soon as it is written.
6. **Append-only.** Never rewrite a prior round's prompt or result.
   Open a new round if the brief needs to change.

## Rules for the executor (whoever writes a result)

1. **Read the latest prompt under the thread directory.** Always pick
   the highest `NN` for `round-NN-prompt.md`.
2. **Respect the gates.** If the prompt declares a wait phrase for a
   phase and the user has not said it, skip that phase and record
   `phase X blocked: awaiting <wait_phrase>` in the result.
3. **Write the report at the declared path.** Default is
   `round-NN-result.md` matching the prompt's NN.
4. **Match the prompt's section structure.** Use one H2 per phase the
   prompt defined, plus the standard `Issues observed` and
   `Manual escalation needed` sections.
5. **Pick the right status** in the frontmatter:
   `complete` (every phase attempted, gated skips counted) /
   `partial` (some phases unreachable due to non-gate blocker) /
   `blocked` (no useful work possible).
6. **Include grep-able fingerprints.** Copy real error strings, exit
   codes, stack frame top lines, SHA tips. Do not paraphrase.
7. **Commit when you write.** Same reason as for prompts.

## Rules for both

1. **Stay public-safe.** This repo is public. No credentials, no
   tokens, no customer data, no secrets in either prompt or result.
2. **Do not improvise around blockers.** If preconditions are not met,
   report and stop. The dispatcher writes the next round if a way
   forward is found.
3. **One thread per topic.** If the work pivots to a different topic,
   close the current thread (move to `archive/`) and open a new one.
4. **Stale-active check.** When picking up an "active" thread that
   has not moved in days, first verify the upstream work has not
   shipped independently outside the handoff channel — check
   submodule `git log`, PR list, and the referenced branch SHAs
   against current `main`. If the work merged via direct review,
   close the thread as superseded rather than re-running the
   prepped phases.

## Slash commands

- `/handoff-open <slug> "<one-line description>"` — dispatcher uses
  this to start a new thread. Creates the directory, seeds
  `round-01-prompt.md` from the template, opens the file for editing.
- `/handoff-result <slug>` — executor uses this. Locates the latest
  `round-NN-prompt.md`, scaffolds `round-NN-result.md` with the right
  frontmatter, and reminds the agent to fill in the body.

Both skills live under `agents/skills/`.

## When NOT to use a handoff

- A user is asking a question in chat that the agent can answer
  directly without any cross-agent coordination.
- The work is a one-shot edit the same agent will finish in this
  session.
- The dispatcher is about to do the work themselves rather than
  delegating.

A handoff has a small fixed overhead (template, frontmatter, commit).
Skip it for tasks where that overhead exceeds the value of having a
durable record.
