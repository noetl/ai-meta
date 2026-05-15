# Cross-agent handoffs

Convention for passing work between AI agents (Claude Code, Codex, Cursor,
Gemini, etc.) using **files instead of chat**, so the receiving agent can
read a stable brief and write its report back to a known path.

A handoff is a small directory under `handoffs/active/<slug>/` containing
one or more numbered prompt/result pairs. The dispatching agent writes
prompts, the executing agent writes results, and either can read the
full thread to decide the next move.

## Why file-based

- A chat-pasted prompt is gone the moment the chat ends. A file persists
  across sessions, machines, and agents.
- The executor's report is captured at a known path. The dispatcher can
  reopen the thread days later and still know exactly what was reported.
- The git history of the thread directory IS the history of the
  collaboration. Reviewers can see who said what without trawling
  screenshots.
- New agents (a third tool, a future Codex version, a teammate) can pick
  up an in-flight thread by reading the files in order.

## Layout

```
handoffs/
  README.md                          # this file
  templates/
    prompt.md                        # copy + rename to round-NN-prompt.md
    result.md                        # copy + rename to round-NN-result.md
  active/
    <YYYY-MM-DD-slug>/               # one directory per thread
      round-01-prompt.md             # dispatcher writes
      round-01-result.md             # executor writes back
      round-02-prompt.md
      round-02-result.md
      ...
  archive/                           # closed threads moved here verbatim
    <YYYY-MM-DD-slug>/
```

### File naming

- `round-NN-prompt.md` — the brief for round NN.
- `round-NN-result.md` — the executor's report for round NN.
- `NN` is zero-padded (`01`, `02`, …, `99`) so the directory listing
  always sorts in chronological order.
- The thread `<slug>` is `<YYYY-MM-DD-short-topic>` (e.g.
  `2026-05-15-runtime-reaper-parser-fix`). The date is the date the
  thread was opened; subsequent rounds keep the same slug.

### Frontmatter

Every prompt and result file begins with YAML frontmatter so an agent can
inspect the header without parsing the body.

**Prompt frontmatter** (`templates/prompt.md`):

```yaml
---
thread: 2026-05-15-runtime-reaper-parser-fix
round: 1
from: claude                        # agent that wrote this
to: codex                           # agent expected to execute
created: 2026-05-15T22:00:00Z       # ISO 8601 UTC
status: open                        # open | answered | closed
expects_result_at: round-01-result.md
wait_phrase: "push parser fix PR"   # optional human gate before any
                                    # destructive action; omit if none
---
```

**Result frontmatter** (`templates/result.md`):

```yaml
---
thread: 2026-05-15-runtime-reaper-parser-fix
round: 1
from: codex
to: claude
created: 2026-05-15T22:35:00Z
in_reply_to: round-01-prompt.md
status: complete                    # complete | partial | blocked
---
```

`status` values for results:

- `complete`  — every phase requested was attempted and reported.
- `partial`   — some phases ran, some were gated and skipped; report
                says exactly which.
- `blocked`   — the executor could not proceed; report names the blocker
                and the precise command(s) a human should run.

## Lifecycle

```
dispatcher                                              executor
==========                                              ========

1. /handoff-open                          ─►            (reads round-01-prompt.md)
   creates handoffs/active/<slug>/
     round-01-prompt.md (status: open)

                                          ◄─           writes round-01-result.md
                                                          (status: complete | partial | blocked)

2. reads round-01-result.md
   decides next move:
     (a) close thread → mv to archive/
     (b) follow-up    → write round-02-prompt.md ─►   (reads round-02-prompt.md)

                                          ◄─           writes round-02-result.md

3. ... repeat until thread closed
```

## How to enter handoff mode in each AI tool

The convention works as long as both agents read/write the same paths.
There is no special tool flag; "handoff mode" is just a behavior.

### Claude Code (this CLI)

**Enter handoff mode** — ask Claude to write a prompt to a file instead
of pasting it to chat:

```
Open a handoff to codex about <topic>. Slug it
<YYYY-MM-DD-short-topic>. Phase A is sanity checks (no remote writes),
B is push PR (gated on "push <thing>"), ...
```

Claude will:

1. Call `/handoff-open <slug> "<one-line description>"` (or do the same
   work manually).
2. Write `handoffs/active/<slug>/round-01-prompt.md` with the brief.
3. Tell you the exact file path to hand to Codex.

**Read a result** — once Codex has written its report:

```
Read handoffs/active/<slug>/round-01-result.md and tell me what to do
next.
```

Claude will read the file, evaluate it against the prompt, and respond
in chat. Subsequent rounds repeat: ask Claude to write
`round-02-prompt.md` whenever you want the executor to do more.

**Return to regular conversation mode** — just keep talking. There is
no mode to exit; the convention only applies when you ask Claude to
write or read a handoff file. Conversation tasks (explaining code,
small edits, reviews) stay in chat.

**Close a thread** when the work is done:

```
Close the handoff <slug>.
```

Claude will `git mv handoffs/active/<slug> handoffs/archive/<slug>` and
commit. The thread is preserved verbatim for posterity.

### Codex

**Enter handoff mode** — start Codex with the absolute path to the
prompt file:

```
You are operating in /Volumes/X10/projects/noetl/ai-meta. Read the
handoff prompt at handoffs/active/<slug>/round-NN-prompt.md
end-to-end, follow the convention in handoffs/README.md, do the work
inside the phase gates, then write your final report to
handoffs/active/<slug>/round-NN-result.md with the matching
frontmatter (status: complete | partial | blocked).
```

Codex will:

1. Read the prompt file.
2. Execute the phases, respecting the gates and wait phrases.
3. Write the result file at the path declared in
   `prompt.expects_result_at`.
4. Commit the result file (do not push) so it shows up in `git log`.

**Return to regular conversation mode** in Codex — just stop pointing
it at handoff files. Codex's default mode is interactive; the file
path is what scopes it to handoff mode.

### Other tools

Cursor, Gemini, and any future agent can join the same convention by
following the same two rules: read the highest-numbered prompt file
under `handoffs/active/<slug>/` and write the matching result file.
The `from`/`to` frontmatter fields are advisory — they tell the
reader which agent wrote it, not which agent must process it next.

## Skills

Two slash commands under `agents/skills/` operationalize the
convention:

- `/handoff-open <slug> "<description>"` — creates a new thread
  directory with `round-01-prompt.md` seeded from the template.
- `/handoff-result <slug>` — for executors. Reads the latest
  `round-NN-prompt.md`, scaffolds `round-NN-result.md` with the
  right frontmatter, and prompts the agent to fill it in.

See [`agents/rules/handoffs.md`](../agents/rules/handoffs.md) for the
behavioral rules every agent operating in this repo must follow.

## Hygiene

- **One thread per topic.** Don't reuse a thread for unrelated work;
  open a new one.
- **Atomic rounds.** A round is one prompt + one result. If a result
  comes back partial, the dispatcher writes a new prompt for the next
  round rather than editing the existing one.
- **Append-only.** Never rewrite a prior round's prompt or result. If
  you need to revise, write a new round.
- **No secrets.** `ai-meta` is public. Prompts and results may
  reference SHAs, branch names, public URLs, and counts of rows, but
  must not embed credentials, tokens, customer data, or anything you
  would not paste into a public GitHub issue.
- **Commit each direction.** Dispatcher commits when they write a
  prompt; executor commits when they write a result. That gives
  reviewers a clean `git log` showing the back-and-forth.

## Example threads

Once a fresh thread runs through end-to-end under this convention,
add a link to it here as the canonical model.

Before the convention existed, single-file briefs were ad-hoc'd
under `playbooks/codex-handoff-*.md`. Those are not round-based and
should not be used as templates for new threads — start from
`handoffs/templates/prompt.md` instead.
