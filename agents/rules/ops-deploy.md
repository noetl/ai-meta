---
paths:
  - "repos/ops/**"
  - "repos/noetl/**"
---

# NoETL Build/Deploy Workflow

When validating `repos/noetl` changes in local kind, use ops playbooks from `repos/ops` instead of ad-hoc kubectl/image scripts.

- Preferred playbook: `repos/ops/automation/development/noetl.yaml`
- Typical redeploy command (from `repos/ops`):
  `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`

This keeps build/deploy behavior consistent with project automation defaults.
