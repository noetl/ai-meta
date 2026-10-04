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

**Critical: the `Closes` keyword ignores trailing qualifiers.**
Writing `Closes noetl/ai-meta#23 Round 02` in the commit body
does NOT mark "only Round 02 done" — GitHub's parser strips
everything after the issue number, sees `Closes
noetl/ai-meta#23`, and closes the whole umbrella issue. Use
`Refs` for partial progress on a multi-round umbrella and
reserve `Closes` for the round that ships the last bit of the
goal. Concrete misfire: ai-meta@e414da9 closed
noetl/ai-meta#23 after Round 02 even though Round 03 (gateway
cleanup) was still ahead — had to reopen with a process-note
comment.

Pointer bumps that close an issue should put the close keyword in
the body, not the subject — the subject stays
`chore(sync): bump <repo> to <short-sha>`.

**And the keyword fires from prose, in any tense, including inside a
heading — negation does not save you.** The parser looks for
`close`/`closes`/`closed`/`fix`/`fixes`/`fixed`/`resolve`/`resolves`/
`resolved` followed by an issue reference, anywhere in the body. It has
no idea what the sentence means.

Concrete misfire, ai-meta@491ce7da (merged as
[#408](https://github.com/noetl/ai-meta/pull/408)): the body carried a
correct `Refs noetl/ai-meta#400` trailer, and seven lines above it a
Markdown heading reading

```
## The reason the obvious fix would not have closed #400
```

That closed [#400](https://github.com/noetl/ai-meta/issues/400) on merge,
while its PR was still unmerged and its own body said "#400 stays open".
A sentence whose entire point was that something *would not* close the
issue is what closed it.

So when a commit body discusses an issue number rather than acting on
it, keep those verbs away from the reference. "satisfied", "addressed",
"covered" all read the same to a human and nothing to the parser:

```
    ## Why the obvious fix would not have satisfied noetl/ai-meta#400
```

Check before pushing a body that mentions an issue number more than
once:

```bash
git log -1 --format=%B | grep -niE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[^A-Za-z0-9]+(noetl/[a-z-]+)?#[0-9]+'
```

Every line that prints will close something. If a line is prose rather
than a trailer, reword it.

Example:

```
chore(sync): bump cli to 9a1da33 (port-conflict probe + global --context)

Lands noetl/cli#17.  Wiki: see noetl-cli-wiki@8a7228a.

Closes noetl/ai-meta#42
```

Trivial commits (`memory(compact):`, `memory(curate):`, formatting
cleanups, doc typos) don't need an issue ref. The threshold matches
issue-tracking.md's "substantive vs inline" line.
