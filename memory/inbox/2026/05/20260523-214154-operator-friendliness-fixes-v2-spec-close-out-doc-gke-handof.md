# Operator-friendliness fixes + v2-spec close-out doc + GKE handoff prepared
- Timestamp: 2026-05-23T21:41:54Z
- Author: Kadyapam
- Tags: noetl,ops,docs,wiki,gke,handoff,operator-fixes,closeout

## Summary
Three follow-ups landed: (1) ops PR #114 — noetl/ops/automation/development/noetl.yaml gets action=reset (deletes 4 namespaces + patches static PV claimRefs on postgres/noetl-data/noetl-logs/noetl-data-pv so the next deploy rebinds cleanly), plus 6×2s retry in verify_test_server_contract's first /health call, plus pod-name targeting via kubectl wait so the contract exec doesn't land on a Terminating pod. Tested locally: action=reset → action=deploy → contract-ok end-to-end no manual intervention. (2) docs PR #168 — adds Section 0 to noetl_distributed_runtime_spec.md covering the close-out: per-phase landing-PR table, Scope A/B consolidation summary, where-to-look table (noetl/noetl vs noetl/ops vs noetl/docs vs each wiki vs ai-meta), wiki entry-point list, and the 2026-05-23 local-kind validation evidence (DB conns, test playbook latency, KEDA scale-up, supercluster mesh). (3) ops-wiki manifests-nats-supercluster page gains Resource footprint section documenting the single-node kind CPU pressure + three mitigations (cluster_size=1, scale-to-0-during-test, larger podman VM). GKE handoff prompt written at handoffs/active/2026-05-23-gke-provision-validation/round-01-prompt.md for codex — targets noetl-cluster in us-central1 project noetl-demo-19700101; covers auth, image strategy (Artifact Registry), storage class adjustments for Autopilot, KEDA + supercluster install, regression tests with side-by-side metrics vs local-kind §0.3 numbers. Pointers: ops 3eca358→4b7fc46, docs c7d4da2→f7284d8, ops-wiki 06529ef→48c5107.

## Actions
-

## Repos
-

## Related
-
