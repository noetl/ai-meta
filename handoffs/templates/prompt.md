---
thread: REPLACE-yyyy-mm-dd-short-topic
round: 1
from: claude                           # agent writing this prompt
to: codex                              # agent expected to execute
created: REPLACE-ISO8601-UTC           # e.g. 2026-05-15T22:00:00Z
status: open                           # open | answered | closed
expects_result_at: round-01-result.md
# wait_phrase: "<short phrase the human must say before any destructive
# action runs>"  — uncomment if this round has any gated phases
---

# REPLACE: short title (under 80 chars)

> **Predecessor:** if this round follows an earlier thread, link the
> previous prompt or result here; otherwise delete this block.

Replace this section with one or two short paragraphs of context the
executor needs to act cold. The executor will read no other chat
history — give them everything that is load-bearing for the task.

## Background

- Where in the repo to operate (paths under `repos/<name>`).
- Which branches, SHAs, files are pre-staged or known-good.
- Any prior round's result (link path under `../`) the executor
  should re-read before starting.

## Phases

Number every phase. Mark each with `*** Run only after explicit human
go-ahead. Wait phrase: <phrase> ***` if it changes shared state
(push, deploy, cancel, rerun, etc.). Phases that are pure verification
or read-only run unattended.

### Phase A — sanity checks (no remote writes)

1. ...
2. ...

### Phase B — REPLACE

> ***Run only after explicit human go-ahead. Wait phrase: `REPLACE`.***

3. ...

## FINAL REPORT

Always emit this, even on early STOP. Write it as the body of
`expects_result_at` with frontmatter:

```yaml
---
thread: REPLACE
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
## Phase A — sanity checks
- ...

## Phase B — REPLACE
- ...

## Issues observed
- bullet list of anything surprising. Include grep-able fingerprints
  (error strings, status codes, stack frames). Do NOT paraphrase.

## Manual escalation needed
- everything you could not complete unattended, with the precise
  command(s) a human should run.
```

## Hard rules for this thread

- Never push to `origin/main` on any repo unless this prompt
  explicitly says so.
- Never force-push.
- Never merge PRs yourself.
- Respect `AGENTS.md` and the rules under `agents/rules/`.
- Do not store secrets in any file under ai-meta (the repo is public).
- If a step's preconditions aren't met, stop and report — don't
  improvise around blockers.
