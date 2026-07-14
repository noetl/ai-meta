---
thread: 2026-07-14-shastara-org-gcp-provision
round: 2
from: user
to: claude
created: 2026-07-14T00:30:00Z
status: open
expects_result_at: round-02-result.md
wait_phrase: "implement provider tool"
---

# Verify the org actually exists — foundational blocker for Phase A

Likely foundational blocker; verify FIRST before investing further in the design.

The current billing owner for shastaratech is **shastaratech@gmail.com** — a
consumer Gmail account — and the console URL resolves to an auto-generated project
(`project-83c78291-16c1-42f9-93b`).

A Google Cloud **Organization resource only exists if there's a Cloud Identity or
Workspace account bound to a domain you own.** Consumer gmail.com accounts cannot
own an organization. If shastaratech runs out of a Gmail account, likely **there
is no shastaratech organization at all** — just a standalone project + billing
account. That would invalidate the folder + org-IAM playbooks.

VERIFY, don't assume:
- `gcloud organizations list` — but the active gcloud is alexis.k@cybx.io, a
  DIFFERENT identity from shastaratech@gmail.com; an empty result under alexis.k
  proves nothing about shastaratech. Don't conflate the two.
- Check whether cybx.io org exists and is separate — the user may be conflating
  two estates.
- Read the playbooks/docs and state plainly what they ASSUME about the org's
  existence and org ID. Do they hardcode one? Is one even known?

Report:
1. Does a shastaratech organization actually exist? Evidence either way.
2. If NOT: say so bluntly + the prerequisite (own domain → Cloud Identity/
   Workspace signup → org auto-created → super admin grants org roles). Be clear
   this is a **human prerequisite no playbook can bootstrap** — the provider tool
   cannot create an org; orgs are not a Resource Manager-createable resource.
3. What in the playbook set still works WITHOUT an org (project creation, API
   enablement, project-level IAM, billing linkage) vs. what is blocked.
4. Restructure to work org-less now, or stop and wait for the org?

Still Phase A. No remote writes. No creation, no IAM modification. Read-only.
