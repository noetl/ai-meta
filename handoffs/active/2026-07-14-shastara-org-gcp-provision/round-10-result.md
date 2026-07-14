---
thread: 2026-07-14-shastara-org-gcp-provision
round: 10
from: claude
to: user
created: 2026-07-14T08:15:00Z
in_reply_to: round-06-prompt.md
status: partial
---

# Round 10 — Stage 2 done + shastara adopted; HARD HALT at Stage 3

folderAdmin grant landed (#3 closed). Resumed Phase B: folders created + verified,
`shastara` adopted, and **HALTED at Stage 3** with the 10 project IDs pre-checked.
**No project created.** Delete of `My First Project` stays queued.

## Stage 2 — 5 folders created + verified
All ACTIVE, all parented to `organizations/561323743912`, no mis-nesting, no extras:

| folder | numeric ID |
| --- | --- |
| 00-shared | folders/443186507149 |
| 10-platform | folders/687234939033 |
| 20-media | folders/654659624272 |
| 30-websites | folders/494018619436 |
| 90-sandbox | folders/259559487513 |

Wrong-org guard pinned throughout. Issue #4 closed with these IDs.

## shastara — adopted (Untracked → Owned)
Confirm-gated: dry-run (`drift: untracked`, digest `fe19ee5a…`) → apply with
`confirm:<digest>`. Result: `import:true`, `changed:false`, `verb:adopt`
`outcome:adopted`, GET-only. **Verified no mutation** — shastara still ACTIVE,
parent unchanged (orphan, NOT moved); stays the ADC quota project. Issue #7 closed.
Caveat: local-mode adopt emits the ownership fact but durable persistence needs a
NoETL server/EHDB (flagged).

## Stage 3 — HARD HALT (pre-check done)
Pre-checked all 10 proposed IDs read-only (format + visibility):

- ⚠️ **`shastaratech-observability-prod` = 31 chars — EXCEEDS the 30-char project-ID
  limit → INVALID, fails at create.** Needs shortening (options:
  `shastaratech-observ-prod`, `shastaratech-obs-prod`, `shastaratech-o11y-prod`).
- Other 9 IDs format-valid.
- None currently visible to us; a third-party global-uniqueness collision can only
  surface at create time.

**Awaiting explicit human confirmation of the final 10 IDs (with the
observability-prod fix) before any project is created.** This gate does not move.
Recorded on issue #5.

## Queued
- **Delete `My First Project`** — behind Stage 3; needs a FRESH digest + explicit
  go at apply (round-9 digest is stale-able).
- After ID confirmation: create 10 projects (two-phase, numeric folder parents
  above) → billing link → API enable → org IAM.
