---
thread: 2026-07-13-noetl-cloud-provider-tools
round: 1
from: codex
to: claude
created: 2026-07-13T15:04:50Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "implement provider tool"
---

# Implement NoETL Cloud Provider Tools For Local Mode

The ShastaraTech `gcp-org-playbooks` repo is moving away from `gcloud` CLI
execution. Its playbooks now emit typed Google API operation specs such as
`folders.ensure`, `projects.ensure`, `services.enable`, and IAM binding
operations. The next platform step belongs in NoETL: implement a provider tool
interface that can execute these specs in local mode through cloud SDKs or REST
clients, starting with Google and leaving a clean shape for AWS and Azure.

This handoff is for Claude to design and implement that option in the NoETL
codebase. The receiving agent should not depend on this chat history; all
load-bearing context is below.

## Background

- Operate in `/Users/akuksin/projects/noetl/ai-meta`.
- Active product repos are submodules under `repos/`.
- The likely implementation target is `repos/noetl`, but inspect the current
  NoETL tool/executor architecture before choosing files.
- Operational references:
  - `repos/ops` for current NoETL operational playbooks.
  - `/Volumes/X10/projects/shastaratech/gcp-org-playbooks` for the new public
    GCP org playbooks.
  - `/Volumes/X10/projects/shastaratech/gcp-org-playbooks/docs/noetl-google-api-runtime.md`
    for the desired provider-tool contract.
- Important external references checked on 2026-07-13:
  - Google announced an official Rust SDK on 2025-09-09:
    <https://cloud.google.com/blog/topics/developers-practitioners/now-available-rust-sdk-for-google-cloud/>
  - Google Rust overview says the SDK supports Cloud Storage, Vertex AI,
    Secret Manager, and 150+ services:
    <https://docs.cloud.google.com/rust/overview>
  - SDK source:
    <https://github.com/googleapis/google-cloud-rust>
- `ai-meta` currently has many unrelated dirty submodule/worktree files. Do not
  clean, reset, or stage unrelated changes.

## Desired Direction

Create a NoETL local-mode provider-tool abstraction:

```yaml
tool:
  kind: provider
  provider: google
  runtime: rust-sdk
  action: google.cloudresourcemanager.projects.ensure
  dry_run: "{{ workload.action != 'apply' }}"
  input:
    project_id: shastaratech-youtube-prod
    parent: folders/by-display-name/20-media
```

The first implementation may be a thin MVP if full Rust SDK coverage is too
large for one round, but the architecture must make these things explicit:

- provider family: `google`, later `aws`, later `azure`
- action name and input schema
- dry-run / plan mode versus apply mode
- authentication boundary outside Git
- normalized JSON result
- no credential logging
- idempotency checks for ensure-style operations

## Initial Google Operation Scope

Support, stub, or clearly design these actions:

- `google.cloudresourcemanager.folders.list`
- `google.cloudresourcemanager.folders.ensure`
- `google.cloudresourcemanager.organizations.iam.get_policy`
- `google.cloudresourcemanager.organizations.iam.ensure_binding`
- `google.cloudresourcemanager.projects.describe`
- `google.cloudresourcemanager.projects.ensure`
- `google.cloudbilling.projects.link`
- `google.cloudbilling.billing_accounts.iam.get_policy`
- `google.cloudbilling.billing_accounts.iam.ensure_binding`
- `google.serviceusage.services.list_enabled`
- `google.serviceusage.services.enable`

These map to the current operation specs emitted by the GCP org playbooks.

## Cross-Cloud Shape

Do not bake Google-only assumptions into the NoETL tool interface. The same
abstraction should later support:

- AWS SDK for Rust for account/IAM/service operations.
- Azure SDK for Rust or generated REST clients for subscription/resource group
  operations.

## Phases

### Phase A — inspect and design (no remote writes)

1. Read `AGENTS.md`, `agents/rules/execution-model.md`, and any relevant
   tool/executor docs in `repos/noetl`.
2. Inspect the current tool kind parsing/execution path.
3. Decide whether the MVP should be:
   - direct Rust implementation in NoETL,
   - a provider adapter binary invoked by NoETL,
   - or an intermediate JSON contract plus executor stub.
4. Write or update a design doc in the relevant NoETL docs location.

### Phase B — implement MVP locally

> ***Run only after explicit human go-ahead. Wait phrase: `implement provider tool`.***

5. Implement the smallest useful provider-tool path.
6. Add tests for:
   - parsing provider tool specs,
   - dry-run behavior,
   - unknown provider/action errors,
   - secret redaction in emitted logs/results.
7. Add sample playbook coverage using one or more `gcp-org-playbooks` style
   operations.
8. Do not make real cloud mutations in tests.

### Phase C — report and integration instructions

9. Report exact files changed, commands run, tests passed/failed, and any API
   coverage left as stubs.
10. If the NoETL implementation lands in a submodule branch, report the branch
    and commit SHA. Do not push or open PRs unless explicitly instructed by the
    human.

## FINAL REPORT

Always emit this, even on early stop. Write it as the body of
`handoffs/active/2026-07-13-noetl-cloud-provider-tools/round-01-result.md`
with frontmatter:

```yaml
---
thread: 2026-07-13-noetl-cloud-provider-tools
round: 1
from: claude
to: codex
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then the report markdown:

```markdown
## Phase A — inspect and design
- ...

## Phase B — implement MVP locally
- ...

## Phase C — report and integration instructions
- ...

## Issues observed
- ...

## Manual escalation needed
- ...
```

## Hard Rules

- Never commit secrets, billing IDs, OAuth files, service-account keys, or token
  caches.
- Never force-push.
- Never rewrite `main`.
- Do not clean or revert unrelated dirty state in `ai-meta` or its submodules.
- Follow the NoETL execution model: gateway is gatekeeper, worker is atomic
  compute, playbook is ephemeral blueprint, shared cache is state vehicle, event
  log is source of truth.
- Data touches must happen inside playbook/provider-tool execution, not in the
  gateway.
