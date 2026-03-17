# published noetl v2.10.3 and removed in-repo automation tree
- Timestamp: 2026-03-06T19:04:05Z
- Author: Kadyapam
- Tags: release,noetl,ops,automation,cleanup

## Summary
Published NoETL v2.10.3 from master fix commit `cac24c7d`, with semantic-release tagging commit `83425dea`. Removed repos/noetl/automation directory and updated bootstrap/CI operational references to use repos/ops automation playbooks.

## Actions
- In `repos/noetl`, merged and pushed to `master`:
- `896864b0` `fix: add agent runtime bridge and catalog agent discovery endpoints`
- `cac24c7d` `fix: remove in-repo automation and switch operational references to ops`
- Release workflow (`.github/workflows/release.yml`) executed on `master` push and published:
- tag: `v2.10.3`
- tagged commit: `83425dea` (`chore(release): version 2.10.3 [skip ci]`)
- release URL: `https://github.com/noetl/noetl/releases/tag/v2.10.3`
- release published at: `2026-03-06T19:03:13Z`
- Removed `repos/noetl/automation/**` (108 files) and redirected key entry points:
- `noetl.yaml` now delegates to `../ops/automation/setup/{bootstrap,destroy}.yaml`.
- `ci/bootstrap/bootstrap.sh` now requires `NOETL_OPS_DIR` (default: sibling `ops`) and runs ops playbooks.
- `ci/bootstrap/test-bootstrap.sh` now checks out `ops` and validates `ops/automation` paths.
- Updated CI/dev/docs command references under `repos/noetl` to `../ops/automation/...`.
- In `repos/docs`, merged and pushed `2199e2b` to `main` to keep agent orchestration docs aligned with runtime implementation.

## Repos
- repos/noetl
- repos/ops
- repos/docs

## Related
- memory/inbox/2026/03/20260306-184655-agent-orchestration-adk-langchain-bridge-implemented.md
- memory/inbox/2026/03/20260306-184841-agent-orchestration-docs-synced-to-implementation.md
