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

## Where operational manifests live

**All Kubernetes manifests for NoETL (the worker / server / projector / outbox / Postgres / NATS / KEDA / NATS supercluster / etc.) live exclusively in [`noetl/ops/ci/manifests/`](https://github.com/noetl/ops/tree/main/ci/manifests).**

The `noetl/noetl` repo's old `ci/manifests/` directory was deleted in the Scope B consolidation (May 2026); only a `ci/MOVED.md` breadcrumb remains there. `automation/development/noetl.yaml` reads from local `ci/manifests/...` paths — the `$NOETL_REPO/ci/manifests/...` pattern is dead.

When adding new operational manifests:

- The committed YAML lives in `noetl/ops/ci/manifests/<subsystem>/`.
- The Python generator that produces it (if any — KEDA, NATS supercluster) lives in `noetl/noetl/noetl/core/runtime/` and emits manifests via `dump_*_yaml` helpers. Regen recipes go in the YAML's header comment.
- The deployment automation (kubectl apply, helm install, etc.) lives in `noetl/ops/automation/`.
- Operational documentation (install / verify / tuning) lives in the `noetl/ops` wiki at <https://github.com/noetl/ops/wiki>.
- Python API documentation for the generator lives in the `noetl/noetl` wiki at <https://github.com/noetl/noetl/wiki>.

See [`agents/rules/wiki-maintenance.md`](wiki-maintenance.md) Rule 0 for the two-wiki convention.
