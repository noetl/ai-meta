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

### ⚠⚠ In a SUBMODULE commit, a closing keyword + a cross-repo issue breaks the release

The `Closes noetl/ai-meta#NN` convention above is for **ai-meta** commits. In a
submodule that runs semantic-release — server, worker, cli, tools, gateway, ehdb,
signal-mesh — it fails the release:

```
[semantic-release] ✘  An error occurred while running semantic-release:
Error: Could not resolve to an Issue with the number of 415.
```

`@semantic-release/github` resolves the closing reference against the **releasing**
repo, not against the one named in it, so it looks for `noetl/server#415`, which does
not exist.

⚠ **GitHub itself handles the same reference correctly** — which is what makes this
confusing. Measured 2026-10-05: the server commit carrying
`Closes noetl/ai-meta#415` **did** close ai-meta#415, at the same minute, by GitHub's
native cross-repo mechanism. So the keyword is not broken; it is **incompatible with
semantic-release**, and the two consumers disagree about the same line.

That is why the recommendation costs nothing: you give up an auto-close you can
perform from ai-meta anyway, and you stop breaking the release.

**The damage is specific and bad.** The failure lands *after* the version is computed
and the tag created, and *before* the step that dispatches `release.yml`:

```
✔  Created tag v3.122.2
✘  Could not resolve to an Issue with the number of 415
```

So the tag exists, the GitHub Release exists, and **no image is ever built**. Nothing
reports that: the release looks real from the tag list and from the releases page, and
only an artifact-registry lookup shows it is empty. Recovering it means dispatching
`release.yml` by hand on the tag.

⚠ **It arms only on a commit type that releases.** `036dd483` on noetl/server carried
`Closes noetl/ai-meta#361` and its run went green, because it was a `ci:` commit and
semantic-release decided *no release* — so it never reached the GitHub step. The
landmine sat there looking safe. Measured 2026-10-05: 1 failure in 60 completed runs,
and the only other commit of that shape was the `ci:` one.

Three data points from that day, which is why the recommendation below is not a guess:

| repo | commit type | reference form | outcome |
| :-- | :-- | :-- | :-- |
| noetl/server | `fix:` | `Closes noetl/ai-meta#415` | ❌ release failed; tag + GitHub Release created, **no image** |
| noetl/server | `ci:` | `Closes noetl/ai-meta#361` | 🟡 green, but only because `ci:` releases nothing |
| noetl/noetl | `fix:` | `Refs noetl/ai-meta#201` | ✅ released 4.26.2 cleanly |

The third row is the one that matters: the safe form works **on a commit that actually
releases**, so switching to it costs nothing.

**So, in a submodule commit body:**

```
    Refs noetl/ai-meta#415                      ✅ safe — not a closing keyword
    https://github.com/noetl/ai-meta/issues/415  ✅ safe — unambiguous
    Closes noetl/ai-meta#415                    ❌ fails the release
```

Close the ai-meta issue from the **ai-meta** side — the pointer-bump commit, or by
hand. That is where the issue lives and where the keyword resolves.

The pre-push detector in the previous section catches this too; on a submodule commit,
treat **every** line it prints as a defect rather than only the prose ones.

Trivial commits (`memory(compact):`, `memory(curate):`, formatting
cleanups, doc typos) don't need an issue ref. The threshold matches
issue-tracking.md's "substantive vs inline" line.
