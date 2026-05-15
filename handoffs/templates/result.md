---
thread: REPLACE-yyyy-mm-dd-short-topic
round: 1
from: codex                            # agent writing this report
to: claude                             # agent that wrote the prompt
created: REPLACE-ISO8601-UTC           # e.g. 2026-05-15T22:35:00Z
in_reply_to: round-01-prompt.md
status: complete                       # complete | partial | blocked
---

# Result — REPLACE-thread-title — round 1

> Mirror the structure of the prompt's "FINAL REPORT" section. Use one
> H2 per phase the prompt defined; add the standard `Issues observed`
> and `Manual escalation needed` sections at the end.

## Phase A — sanity checks
- ...

## Phase B — REPLACE
- ...

<!-- Add one H2 per phase the prompt declared. Use exactly the phase
     names from the prompt so the dispatcher can grep them. -->

## Issues observed
- bullet list of anything surprising. Include grep-able fingerprints
  (error strings, status codes, stack frames). Do NOT paraphrase.

## Manual escalation needed
- everything you could not complete unattended, with the precise
  command(s) a human should run.

<!--
  Status guidance:

  - complete  → every phase requested was attempted and reported;
                gated phases that were correctly skipped count as
                attempted (their bullet should say
                "phase X blocked: awaiting <wait_phrase>" or
                "phase X blocked: PRs not merged yet").
  - partial   → some phases ran, some were not reached because of a
                blocker that is NOT a normal gate (e.g. CI failed,
                Podman down). Spell out which phases ran and which
                did not.
  - blocked   → no useful work could be done. Issues observed +
                Manual escalation needed should be exhaustive.
-->
