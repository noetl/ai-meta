---
thread: 2026-07-14-shastara-org-gcp-provision
round: 6
from: user
to: claude
created: 2026-07-14T03:45:00Z
status: open
expects_result_at: round-06-result.md
wait_phrase: "implement provider tool"
---

# Final Phase A — incorporate the two existing projects via adopt

Pre-flight complete + verified. Ground truth:
- ADC identity = the shastaratech owner account (tokeninfo-verified, cloud-platform
  scope), sees ONLY shastaratech-org.
- ORG_ID 561323743912; billing `<BILLING_ACCOUNT_ID>` open, parent = org.
- Quota/bootstrap project = `shastara`, with crm/serviceusage/cloudbilling enabled;
  ADC quota project set.

TWO EXISTING PROJECTS, different states:

| project | parent | state |
|---|---|---|
| `shastara` (1018756743824) | EMPTY — no parent | ORPHAN, outside the org |
| `project-83c78291-16c1-42f9-93b` ("My First Project", 401992377820) | org root | inside org, in no folder |

Neither is in the target folder structure. Incorporate both explicitly — do not
ignore, do not silently delete:

1. **`shastara` is an orphan** predating the org; also the **ADC quota project** →
   load-bearing for the very calls that build the org (deleting/moving mid-run
   could break the run — say so). Options: move to `90-sandbox`, leave as
   deliberate bootstrap project, or delete. Tradeoffs; don't decide destructively.
2. **`My First Project`** under org root, no folder. Move into a folder (which?) or
   delete (confirm-gated, never silent).
3. **Adopt angle — the dogfood moment.** These are the `Untracked → Owned` case the
   round-4 `adopt` verb was built for. Show how `noetl provider adopt` brings them
   under management WITHOUT recreating. If they'd be reported as orphans/untracked,
   show that too.

Also: project deletion = 30-day soft-delete but the **project ID is NEVER reusable**
even after deletion — make that explicit in the irreversibility list.

Produce the final Phase A report: reconciled design, resource-by-resource dry-run
plan (folders → projects → billing link → API enable → IAM), proof the wrong-ORG_ID
guard REFUSES, the adopt path for the two existing projects, YouTube scope verdict,
irreversibility list, what remains before Phase B.

Still Phase A. NO REMOTE WRITES. Wait phrase remains `implement provider tool`.
