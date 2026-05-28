# Commit Conventions

Use these prefixes for ai-meta commits:

- `memory(add): <topic>` — new memory inbox entry
- `memory(compact): <scope or date>` — compaction run
- `memory(curate): <scope>` — manual current.md refresh
- `chore(sync): bump <repo> to <short-sha>` — submodule pointer update
- `docs(agents): <description>` — instruction/agent doc changes
- `handoff(open): <slug>` — first `round-NN-prompt.md` in a thread
- `handoff(prompt): <slug> round NN` — follow-up prompt
- `handoff(result): <slug> round NN` — executor result
- `handoff(close): <slug>` — moved thread to `handoffs/archive/`

## Issue references in commits

Substantive ai-meta commits (pointer bumps for behavior changes,
rule changes that close an open question, etc.) should cite the
ai-task issue they relate to, per
[`issue-tracking.md`](issue-tracking.md). Use GitHub's standard
keywords in the commit body so the issue auto-closes when the
commit reaches `origin/main`:

- `Closes noetl/ai-meta#NN` — when this commit fully satisfies the
  issue's `## Goal`. Auto-closes the issue.
- `Refs noetl/ai-meta#NN` — when the commit progresses the issue
  but doesn't close it. Does not auto-close.

Pointer bumps that close an issue should put the close keyword in
the body, not the subject — the subject stays
`chore(sync): bump <repo> to <short-sha>`.

Example:

```
chore(sync): bump cli to 9a1da33 (port-conflict probe + global --context)

Lands noetl/cli#17.  Wiki: see noetl-cli-wiki@8a7228a.

Closes noetl/ai-meta#42
```

Trivial commits (`memory(compact):`, `memory(curate):`, formatting
cleanups, doc typos) don't need an issue ref. The threshold matches
issue-tracking.md's "substantive vs inline" line.
