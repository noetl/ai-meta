---
thread: 2026-07-14-shastara-org-gcp-provision
round: 4
from: user
to: claude
created: 2026-07-14T02:00:00Z
status: open
expects_result_at: round-04-result.md
wait_phrase: "implement provider tool"
---

# Bootstrap complete — finish Phase A with the multi-org safety guard

Identity gate open (verified):
- The runner identity (`@cybx.io`) holds org-level organizationAdmin, folderAdmin,
  projectCreator, iam.securityAdmin, serviceUsageAdmin on **561323743912**, plus
  billing.admin.
- Billing account `<BILLING_ACCOUNT_ID>`: `open: true`,
  `parent: organizations/561323743912` (describe works; list had propagation lag).
- Provider tool authenticates via **ADC** — remind the user to run
  `gcloud auth application-default login` if ADC isn't fresh.

🚨 CRITICAL SAFETY REQUIREMENT — design it and prove it in the dry-run.

The runner identity can see THREE orgs: adiona.org (103794563683), shastaratech-org
(561323743912 ← ONLY valid target), cyberionix.com (712221118891). If ORG_ID is
ever unset/defaulted/inherited from ambient gcloud config or ADC quota-project, a
run could land folders/IAM in the wrong org. Org-scope mistakes are not a clean
undo.

1. ORG_ID 561323743912 explicitly pinned in every playbook — never defaulted.
2. Runtime pre-flight assertion: resolve target org, HARD FAIL if not 561323743912
   (also check display_name == shastaratech-org). Wrong-org run must be
   structurally impossible.
3. Same for billing: pin `<BILLING_ACCOUNT_ID>`, assert
   `parent == organizations/561323743912` before linking.
4. Prove BOTH guards in the dry-run: show a deliberately wrong ORG_ID is REFUSED.
   The test, not a comment.

Mirror the confirm-gate discipline from destroy/adopt: make the dangerous thing
structurally impossible, not merely unlikely.

Report: reconciled design; resource-by-resource dry-run PLAN (org → folders →
projects → billing link → API enable → IAM); proof of wrong-org guard refusing;
YouTube scope verdict; irreversibility list; what's needed before Phase B.

Still Phase A. NO REMOTE WRITES. Phase B wait phrase remains `implement provider tool`.
