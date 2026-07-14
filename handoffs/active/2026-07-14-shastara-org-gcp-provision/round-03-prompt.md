---
thread: 2026-07-14-shastara-org-gcp-provision
round: 3
from: user
to: claude
created: 2026-07-14T01:00:00Z
status: open
expects_result_at: round-03-result.md
wait_phrase: "implement provider tool"
---

# Blocker cleared — org exists. Design against real desired state (Phase A)

The organization now exists. Real values (billing ID + personal emails are
runtime-only — kept OUT of git / masked in this public repo):

- **ORG_ID = 561323743912** (`shastaratech-org`)
- **Billing account** = `<BILLING_ACCOUNT_ID>` (Active, linked to shastaratech-org)
- Cloud Identity super admin / break-glass root: the shastaratech root account.
- Target admins: two identities (one `@cybx.io`, one `@gmail.com`).

Target folder structure (desired state to design against):

```
shastaratech-org
├── 00-shared      → shastaratech-billing-admin, shastaratech-dns-prod, shastaratech-observability-prod
├── 10-platform    → shastaratech-noetl-dev, shastaratech-noetl-prod, shastaratech-ai-lab
├── 20-media       → shastaratech-youtube-prod
├── 30-websites    → shastaratech-web-dev, shastaratech-web-prod
└── 90-sandbox     → shastaratech-sandbox
```

Immediate priority: **shastaratech-youtube-prod** in `20-media` (YouTube OAuth
scopes / upload quotas isolated from NoETL and web).

STILL PHASE A. No remote writes. No Phase B until `implement provider tool`.

Tasks:

1. **Identify the bootstrap chicken-and-egg explicitly.** The playbooks run as
   some identity that almost certainly has NO org-level permission yet — the org
   was just created by the root account. Confirm read-only
   (`gcloud organizations get-iam-policy 561323743912`) and state: which identity
   runs the playbooks, what it currently has, the minimum it needs, and what the
   human must do first. Do not attempt any grant.
2. **Reconcile the existing playbooks** against the target structure + real
   ORG_ID/billing. Match? Drift, stubs, placeholders? Whole graph or part?
3. **Dry-run PLAN** — `noetl provider plan` / dry_run over the full desired state,
   correct dependency order (org → folders → projects → billing link → API enable
   → IAM). Resource by resource. No network writes; live GETs need explicit
   `auth:` — name the credential, don't improvise.
4. **YouTube scope call.** Project + billing + enable `youtube.googleapis.com` =
   provider wheelhouse. Uploading videos = YouTube Data API = content publishing,
   not infra. State in/out of scope; if out, what carries it.
5. **Irreversibility list.** Globally-unique never-reusable project IDs, folder
   deletion, org policy, billing detach. The section the user most needs.
6. The existing `shastara` project should be kept as sandbox or cleanly deleted —
   flag deletion as confirm-gated/destructive; do not plan it silently.

No writes.
