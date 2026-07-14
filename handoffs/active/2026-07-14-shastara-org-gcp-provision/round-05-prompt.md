---
thread: 2026-07-14-shastara-org-gcp-provision
round: 5
from: user
to: claude
created: 2026-07-14T03:00:00Z
status: open
expects_result_at: round-05-result.md
wait_phrase: "implement provider tool"
---

# Finish Phase A — acting identity changed to the org-scoped owner; verify it

ADC is live (`print-access-token` OK). Acting identity for shastaratech-org work is
now the **shastaratech owner account** (a `@gmail.com` identity), NOT the `@cybx.io`
identity. Reason: the owner account can see ONLY shastaratech-org, whereas the
`@cybx.io` identity can see three orgs — running as the identity structurally
incapable of reaching the other two removes the blast radius rather than merely
guarding it.

VERIFY read-only (ADC and CLI session are separate stores; the browser may have
consented as the wrong account):

1. **Assert the ADC identity** (tokeninfo against print-access-token) == the
   shastaratech owner account. If it's the `@cybx.io` identity, STOP and report.
2. **Assert the org** — visible orgs under that credential; confirm 561323743912 /
   shastaratech-org is the target and ideally the only one.
3. Confirm the ADC identity holds the needed roles (org admin / folder admin /
   project creator / serviceusage admin; billing admin on the billing account).

Deliver the Phase A report: reconciled design; resource-by-resource dry-run PLAN
(folders → projects → billing link → API enable → IAM); proof of the wrong-org
guard REFUSING (not just a comment); YouTube scope verdict (project + API enable in
scope; video upload via YouTube Data API out of scope — say what carries it);
irreversibility list; what remains before Phase B.

For the record: long-term correct answer is a **dedicated service account inside
shastaratech-org** with only the roles the playbooks need — automation shouldn't run
as a human, and an SA also can't see the user's other orgs. Recommend, don't build.

Still Phase A. NO REMOTE WRITES — read-only GETs only. Phase B wait phrase remains
`implement provider tool`.
