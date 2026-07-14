---
thread: 2026-07-14-shastara-org-gcp-provision
round: 1
from: user
to: claude
created: 2026-07-14T00:00:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "implement provider tool"
---

# Provision shastara-org GCP structure via the NoETL provider tool (Phase A)

First real dogfood of the `kind: provider` tool shipped in noetl-tools 3.25.0
(`noetl provider plan/drift/orphans/adopt`, noetl-cli 4.17.0). The user wants the
Google org structure for **shastara-org** created — folders, projects, IAM,
billing, plus a YouTube publisher project for uploading videos — driven by NoETL
playbooks, not Terraform.

This is a **separate topic** from the provider-tool implementation thread
(`handoffs/active/2026-07-13-noetl-cloud-provider-tools/`, which built the tool).
This thread applies the tool to shastara-org. Per `handoffs/README.md` hygiene
("one thread per topic"), it lives in its own directory so the round-1
implementation record is not clobbered.

## Phase A — inspect and design ONLY. NO REMOTE WRITES.

No GCP mutations of any kind: no folder creation, no project creation, no IAM
binding, no billing changes, no API enablement, no YouTube API calls. Read, plan,
design, dry-run. Nothing that changes state in Google Cloud. Do not proceed to
Phase B until the user says the exact wait phrase `implement provider tool`.

### Deliverables

1. **Inspect** the shastara-org playbooks. What's modelled (folders, IAM,
   billing, project factory, youtube publisher)? Complete / stub / missing?
2. **Gap analysis against the tool's actual capability** (Google via REST: Cloud
   Resource Manager v3, Cloud Billing v1, Service Usage v1). Be blunt about what
   the design needs that the tool does NOT cover — IAM bindings, billing
   association, org policy, and especially YouTube Data API video upload (a
   different API surface; uploading videos is NOT resource-management — say so if
   it's out of scope).
3. **Design** the playbook set: resource graph, dependency order (org → folders →
   projects → billing → APIs → IAM), the `stack:` scoping label, and how
   `dry_run` / confirm-gating applies at each step.
4. **Produce the PLAN** — run the provider tool in dry-run / `noetl provider
   plan` so the user can SEE what would be created, resource by resource, before
   approving. Dry-run must make NO network writes. If reaching Google read-only
   (GET) for current-state is needed, that requires explicit `auth:` — say what
   credential it needs and STOP rather than improvising one.
5. **Call out the risks.** Org-level ops are high-blast-radius and some are
   irreversible (org policy, folder hierarchy, globally-unique non-reusable
   project IDs). Name what cannot be undone.

### Constraints

- ai-meta has unrelated dirty state: do NOT reset, clean, revert, or stash.
- No secrets, no credential creation, no service-account key minting.
- No prod/GKE actions. No kind mutations.
- Report first. Open nothing, merge nothing, apply nothing.

Context repos:
`/Volumes/X10/projects/shastaratech/gcp-org-playbooks` (whole repo + wiki),
NoETL impl `repos/noetl` / `repos/tools` / `repos/cli`, ops examples `repos/ops`.
