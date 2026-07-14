---
thread: 2026-07-14-shastara-org-gcp-provision
round: 11
from: claude
to: user
created: 2026-07-14T09:30:00Z
in_reply_to: round-06-prompt.md
status: partial
---

# Round 11 — 10 projects created (milestone); billing blocked on account cap

Stage 4 project creation — the big irreversible step — is **done and verified**.
Billing linkage is **partial, blocked on the billing account's project-count cap**.
`My First Project` delete has a fresh valid digest, awaiting your go.

## Projects — all 10 created, ACTIVE, correct parent (IDs locked)
| project ID | number | folder |
| --- | --- | --- |
| shastaratech-billing-admin | 642438310591 | 00-shared |
| shastaratech-dns-prod | 91001183734 | 00-shared |
| shastaratech-obs-prod | 689487542384 | 00-shared |
| shastaratech-noetl-dev | 135470027868 | 10-platform |
| shastaratech-noetl-prod | 986938120811 | 10-platform |
| shastaratech-ai-lab | 576489511885 | 10-platform |
| **shastaratech-youtube-prod** | **737655213161** | 20-media |
| shastaratech-web-dev | 187140100197 | 30-websites |
| shastaratech-web-prod | 53720349864 | 30-websites |
| shastaratech-sandbox | 1014446858636 | 90-sandbox |

Wrong-org guard pinned throughout. Two snags handled:
- **obs display name** shortened to "ShastaraTech Obs Prod" (display names cap at 30
  chars, same as IDs). ID stays the locked `shastaratech-obs-prod`.
- **Real tool bug fixed:** `projects.ensure` GET-first errored on Google's
  403-may-not-exist (returned instead of 404 for a non-existent project). Now
  treats 403/404 alike as absent → create; unit test added
  (`ensure_project_creates_on_403_may_not_exist`). 64 provider tests green;
  binary rebuilt (still noetl-tools 3.26.0, unreleased). Issue #6 closed.

## Billing — 4/10 linked, BLOCKED on billing-account project cap
Linked: billing-admin, dns-prod, obs-prod, noetl-dev. Then
`400 FAILED_PRECONDITION`. Cause: the billing account is at its **5-project cap**
(default self-serve limit) — currently My First Project + those 4. The remaining 6
(**including youtube-prod, the priority**) cannot link until the cap is raised.

**Unblock paths:**
1. Request a **billing quota increase** (human, Console) → link the remaining 6.
2. **Delete `My First Project`** (#8) → frees exactly 1 slot → specifically
   unblocks youtube-prod's billing link. (Still need option 1 for the other 5.)

Issue #9 commented with this.

## Delete `My First Project` — fresh digest ready (NOT applied)
- Quota re-confirmed: ADC `quota_project_id = shastara` — the delete target is a
  different project; deletion cannot affect ADC/quota.
- Fresh dry-run digest: `e19319c374e47b34f720dd18d834cd506a29930c23bc182dfbc312b9fc48b061`
  (unchanged from round 9 because the project state is unchanged — so it is
  current, not stale). Target: `DELETE projects/project-83c78291-16c1-42f9-93b`,
  state ACTIVE, etag `W/"010d7c52c1d27428"`.
- **Awaiting your explicit go** before apply. Recovery: `gcloud projects undelete
  project-83c78291-16c1-42f9-93b` within 30 days (auto-generated id, burn harmless).

## Wiki + tracking
- Wiki `Runbook` updated: real folder ids + realized project taxonomy + obs-prod
  note + billing-cap & 403 gotchas; `Home` shows provisioning status (wiki `4261ad5`).
- Issues: #6 closed (projects); #9 commented (billing cap). #5 closed (IDs locked).

## Remaining
- **Billing** (#9): 6 links pending on cap increase / slot free.
- **API enablement** (#10): held for youtube-prod until its billing links (some
  APIs need billing). Others can enable independently.
- **Org IAM** (#11): declared bindings, least-privilege — pending.
- **Delete** (#8): awaiting go + then frees youtube-prod's billing slot.

Secrets: billing account id + emails never committed (runtime `--set`).
