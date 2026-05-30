# Appendix H expanded: MinIO exclusion + § H.11 local Feather buffer + § H.12 dynamic playbooks
- Timestamp: 2026-05-30T03:13:51Z
- Author: Kadyapam
- Tags: rust,architecture,appendix-h,minio,arrow,ai-agents,issue-30,pr-175

## Summary
Three additions to PR noetl/docs#175 covering user feedback after the § H.10 tree-walker finding: (1) Object-store policy excludes MinIO from the recommended adapter list across 10 sections (§ 5, 7, 8, 14, 18, C.2, F.2, F.3, G.1) — Ceph RGW + SeaweedFS recommended for in-house; MinIO retained only in compliance-fixture suite. (2) § H.11 documents local-mode Arrow Feather batch buffering — CLI buffers events + commands in RecordBatch to a per-execution Feather V2 file under ~/.noetl/local/<execution_id>/, pushes one batched HTTP envelope to event log at exit. Schema, three-trigger flush policy, push-to-server contract, new R-1.4 phase. (3) § H.12 documents dynamically-generated playbook execution units per noetl.dev/docs/ai-meta/agent-orchestration — third source alongside catalog YAML and CLI files. Identity via kind: ephemeral catalog rows. Trust boundary: grants NOT inherited from generating agent; explicit delegable_credentials set + tool-kind allowlist. Persistence audit: every generated playbook in execution archive. Shape under § H.9 PyO3 endpoint: typed Playbook builder API crossing PyO3 once per unit. New Phase R-5 for ephemeral-playbook support after R-4 ships.

## Actions
-

## Repos
-

## Related
-
