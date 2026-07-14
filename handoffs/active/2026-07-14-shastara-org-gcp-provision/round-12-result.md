---
thread: 2026-07-14-shastara-org-gcp-provision
round: 12
from: claude
to: user
created: 2026-07-14T11:30:00Z
in_reply_to: round-06-prompt.md
status: partial
---

# Round 12 — delete + billing + APIs done; org IAM HALTED for review

Executed the five approved decisions in order. **Steps 1–3 done, step 4 (IAM)
HALTED as instructed, step 5 (sink) next.**

## 1. `My First Project` — DELETED
- Pre-apply re-checks: quota project = `shastara` (not the target); target empty;
  fresh digest `e19319c374e47b34f720dd18d834cd506a29930c23bc182dfbc312b9fc48b061`
  (current, matched).
- Applied confirm-gated destroy → `DELETE_REQUESTED`, deleteTime
  2026-07-14T23:34:10Z. Recovery: `gcloud projects undelete
  project-83c78291-16c1-42f9-93b` before **~2026-08-13**. #8 closed.

## 2. Billing — 5/10 linked (youtube-prod ✓), 5 blocked
- The delete freed a slot → **youtube-prod (priority) linked**.
- Linked (5, at cap): billing-admin, dns-prod, noetl-dev, obs-prod, youtube-prod.
- Blocked (5): noetl-prod, ai-lab, web-dev, web-prod, sandbox.
- **Quota-increase path (not API-self-service):** Console → Billing → the account →
  Help/Support → request a higher "projects per billing account" limit (or it
  auto-raises with account history). Then re-run the billing-link playbook for the
  5 (idempotent). #9 updated.

## 3. API enablement — baseline on all 10, full set on youtube-prod
- All 10: cloudresourcemanager + serviceusage + cloudbilling (3/3). youtube-prod:
  + youtube + iam (5/5). Baseline enabled even on billing-unlinked projects.
- **Tool bug fixed:** `services.enable`'s LRO poll hit the CRM endpoint instead of
  Service Usage ("unsupported operation name"). Now polls the operation against the
  service that created it; regression test `ensure_service_polls_serviceusage_not_crm`
  added (65 provider tests green). #10 closed.

## 4. Org IAM — HALTED (least-privilege guard)
Read-only delta of the declared bundle vs current org policy:
- **Both named admins already hold the full 5-role bundle — idempotent, no change.**
- **Root/owner account: would gain exactly one role — `roles/iam.securityAdmin`**
  (already holds the broader organizationAdmin). No new members, no unexpected
  principals.
- **Not applied.** Awaiting go on the single addition. #11 commented (masked).

## 5. State sink — NEXT (build authorized)
Not started this round (kept provisioning + the IAM HALT as the checkpoint). Scope
unchanged: CLI-only JSONL append on apply, `--facts-out`, backward-compat
`load_facts`, round-trip test, noetl-cli version bump only. PR open, not merged;
diff reported before it lands. #12.

## Two tool fixes this session (dogfood-surfaced), on branch feat/provider-org-guard
- `projects.ensure`: 403-may-not-exist treated as absent→create.
- `services.enable`: LRO polled against the wrong host.
Both unit-tested; still noetl-tools 3.26.0 (unreleased); binary rebuilt.

## Tracking / wiki
- Issues #8, #10 closed; #9, #11 commented; #12 (sink) open.
- Wiki Home provisioning status refreshed (delete/APIs/billing/IAM). Runbook carries
  the 403 + billing-cap gotchas (LRO gotcha to add with the sink round).
- No secrets committed (billing id + emails runtime-only; IAM delta masked in the issue).
