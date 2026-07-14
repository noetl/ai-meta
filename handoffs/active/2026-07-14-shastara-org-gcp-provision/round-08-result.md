---
thread: 2026-07-14-shastara-org-gcp-provision
round: 8
from: claude
to: user
created: 2026-07-14T06:00:00Z
in_reply_to: round-06-prompt.md
status: blocked
---

# Round 8 — Phase B STAGE 2 BLOCKED: acting identity lacks `folders.create`

Stage 2 (create the 5 folders) was attempted with the guarded binary and is
**blocked on a missing IAM permission**. **No folders were created** (verified
read-only: folders under the org = none). The guard and the tool worked
correctly — the block is a Google-side IAM denial, downstream of a clean guard
pass and a real API call. This is a **human IAM grant** I will not make myself.

## What happened

The plan (dry-run) for all 5 folders passed the guard and planned cleanly. The
apply then hit, for every folder:

```
HTTP 403 for POST https://cloudresourcemanager.googleapis.com/v3/folders
Permission 'resourcemanager.folders.create' denied on resource
'//cloudresourcemanager.googleapis.com/organizations/561323743912'
reason: IAM_PERMISSION_DENIED
```

## Diagnosis (read-only)

The acting identity (the shastaratech owner) currently holds on the org:
`resourcemanager.organizationAdmin`, `resourcemanager.projectCreator`,
`resourcemanager.projectMover`, `serviceusage.serviceUsageAdmin`,
`billing.admin`, `billing.creator`, `iam.workforcePoolAdmin`.

`testIamPermissions` on the org confirms precisely:
- ✅ holds `resourcemanager.projects.create`
- ✅ holds `resourcemanager.folders.list`
- ❌ **does NOT hold `resourcemanager.folders.create`**

**Root cause:** `roles/resourcemanager.organizationAdmin` does **not** include
`folders.create`. It grants org-IAM management + browsing, and projectCreator
covers projects — but folder *creation* needs `roles/resourcemanager.folderCreator`
or `roles/resourcemanager.folderAdmin`. This is exactly the `folderCreator /
folderAdmin` grant flagged as required in round 3 (§1 role table); the bootstrap
granted `organizationAdmin`, which reads as "can do everything" but does not
cover folder creation.

Notably: **`projects.create` IS held**, so Stage 4 (projects) is not blocked by
this — only folders (Stage 2) are.

## The fix (human step — I will not grant IAM)

The org owner grants the acting identity folder-create rights at the org. The
owner already holds `organizationAdmin` (which includes org `setIamPolicy`), so
the owner **can self-grant** this. Minimal vs. full:

- **Minimal** — `roles/resourcemanager.folderCreator` (create only):
  ```
  gcloud organizations add-iam-policy-binding 561323743912 \
    --member="user:<acting-identity>" \
    --role="roles/resourcemanager.folderCreator"
  ```
- **Full** — `roles/resourcemanager.folderAdmin` (create + move + delete + folder
  IAM; needed anyway if you'll later move `shastara` / `My First Project` into
  folders or reorganize):
  ```
  gcloud organizations add-iam-policy-binding 561323743912 \
    --member="user:<acting-identity>" \
    --role="roles/resourcemanager.folderAdmin"
  ```

Recommend **`folderAdmin`** — the later adopt/move of the two existing projects
into `90-sandbox` (round 6) needs folder move/IAM, and it's the same grant the
round-3 role bundle called for.

(This can also be done in Console → IAM & Admin → the org → grant the role. Do it
as the owner or any identity holding org `setIamPolicy`.)

## State after Stage 2

- **No folders created** (403 denied every create; verified none exist).
- **No other resources touched** — no projects, IAM, billing, or APIs.
- The guarded binary + playbook are proven correct end-to-end: guard passed for
  the right org, the real API call was made, and the only failure is the IAM
  denial (not a tool bug).
- The Stage-2 playbook is written and ready:
  `gcp-org-playbooks/automation/gcp_org/org_folder_one_provider.yaml`
  (single-folder, guarded, `--set display_name=<f>`; `--set dry_run=false` to
  apply). I added it to the shastara repo working tree; **not committed/pushed**
  — yours to review.

## Next

Once you grant `folderCreator`/`folderAdmin`, re-running the 5 folder applies
completes Stage 2 (idempotent GET-first — safe to re-run). Then **Stage 3 HALTS**
for your explicit confirmation of all 10 project IDs before any project is
created (project IDs are the irreversible thing).

## Manual escalation needed

- **Grant `resourcemanager.folderCreator` (or `folderAdmin`) to the acting
  identity at org `561323743912`** — human IAM step; I did not and will not
  perform it. This is the only thing blocking Stage 2.
- Everything else (guard, binary, playbook) is ready; Stage 2 resumes the moment
  the grant lands.
