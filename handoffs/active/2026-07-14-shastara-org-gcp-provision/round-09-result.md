---
thread: 2026-07-14-shastara-org-gcp-provision
round: 9
from: claude
to: user
created: 2026-07-14T07:30:00Z
in_reply_to: round-06-prompt.md
status: partial
---

# Round 9 — delete inventory + dry-run, issue tracking, wiki runbook

Provisioning remains **paused on the `folderAdmin` grant** (round 8). This round
did the read-only + additive work that doesn't need it: the `My First Project`
deletion prep (inventory + confirm-gated dry-run), and the new standing
requirement (GitHub issues + wiki runbook). **No cloud writes.**

## Decisions recorded
- **`shastara` → adopt + KEEP** (Untracked→Owned, no move/delete; stays ADC quota
  project). Ordered after folders exist.
- **`My First Project` → DELETE** via inventory-first + confirm-gated destroy.

## My First Project (`project-83c78291-16c1-42f9-93b`, 401992377820) — inventory (read-only)
**Genuinely empty default project — safe to delete:**
- ACTIVE, under org root; billing linked (`billingEnabled`) but nothing consumes
  it → effectively $0 spend.
- Default APIs on (BigQuery, storage, datastore, logging/monitoring) but: **no
  BigQuery datasets, no Firestore/Datastore DB (API off), no Cloud SQL (API off),
  no GCS buckets, no service accounts, no compute (API off), no App Engine, no
  Secret Manager, no Pub/Sub.**
- **Quota-safe (verified):** ADC `quota_project_id = shastara` — the delete target
  is a *different* project, so deletion cannot affect ADC/quota.

## Delete dry-run (confirm-gated, NO deletion)
```
action : google.cloudresourcemanager.projects.delete
plan   : DELETE .../v3/projects/project-83c78291-16c1-42f9-93b
         present=true, state=ACTIVE, etag W/"010d7c52c1d27428"
plan_digest : e19319c374e47b34f720dd18d834cd506a29930c23bc182dfbc312b9fc48b061
```
Apply is gated: **folders exist → shastara adopted → your explicit go → a FRESH
digest at apply** (the digest above is live-resolved; a stale one is refused by
design). Recovery if ever needed: `gcloud projects undelete
project-83c78291-16c1-42f9-93b` within 30 days (ID stays burned — harmless, it's
an auto-generated id nobody wants).

## GitHub issues (shastaratech/gcp-org-playbooks)
Umbrella + one issue per unit of work, each with what / why / gate / verification
/ rollback, cross-linked:
- **#1** umbrella (tracking)
- **#2** Stage 1 guard/tool — **CLOSED** with evidence (offline+live refusal proofs)
- **#3** Stage 2a IAM bootstrap grants — commented (folderAdmin blocker)
- **#4** Stage 2b folder creation — commented (attempted, 403, blocked by #3)
- **#5** Stage 3 project-ID confirmation (hard halt)
- **#6** Stage 4a project creation (blocked by #5)
- **#7** Stage 4b adopt shastara
- **#8** Stage 4c delete My First Project — commented (inventory done, digest ready)
- **#9** Stage 4d billing linkage (blocked by #6)
- **#10** Stage 4e API enablement (blocked by #6, #9)
- **#11** Stage 5 org IAM

## Wiki (shastaratech/gcp-org-playbooks/wiki)
- **`Runbook`** — new page: from-zero provisioning procedure (prerequisites,
  ordered steps with gate/verify/rollback per step, reference taxonomy + SA
  recommendation, and a gotcha quick-reference). Includes every trap that bit us:
  org prerequisite (gmail can't own an org), IAM bootstrap chicken-and-egg,
  `organizationAdmin` ≠ folder create, billing IAM separate from org IAM, ADC ≠
  CLI session (+ tokeninfo one-liner), consent-screen scope trap, quota-project
  load-bearing trap, multi-org blast radius, project-ID irreversibility,
  untracked/orphan/drift + adopt≠conform, gate discipline.
- **`Home`** — refreshed (removed the stale "provider tool not implemented yet";
  links the Runbook + issue tracker).
- Pushed to wiki master `2cecbbe`.

**Secrets:** no billing account id, no personal emails in any issue or wiki page —
placeholders + "runtime value" throughout.

## Still blocked / next
- **Blocker unchanged:** grant `roles/resourcemanager.folderAdmin` to the
  automation identity at org `561323743912` (#3). Everything downstream waits on it.
- On grant: resume Stage 2 (folders) → adopt shastara (#7) → **HALT at Stage 3
  (#5)** for your 10 project-ID confirmation → then projects/delete/billing/APIs/IAM.
