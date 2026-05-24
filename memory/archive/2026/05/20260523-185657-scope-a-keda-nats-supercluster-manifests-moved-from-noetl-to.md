# Scope A — KEDA + NATS supercluster manifests moved from noetl to ops repo
- Timestamp: 2026-05-23T18:56:57Z
- Author: Kadyapam
- Tags: noetl,ops,ci-manifests,phase4,refactor,scope-a,cross-repo

## Summary
Cross-repo refactor splitting Phase 4 operational manifests off from application code. PRs: noetl/ops#112 (additions, merge cf9a572) + noetl/noetl#598 (deletions, merge 2d51caeb, v2.100.2) + noetl-wiki@b0eb581 (link updates). What moved: ci/manifests/keda/ + ci/manifests/nats-supercluster/ from noetl/ci/manifests/ to ops/ci/manifests/. What stayed in noetl/noetl: the Python generators (noetl/core/runtime/keda.py + nats_topology.py) and their unit tests. What was dropped: 4 drift-guard tests that read the committed YAML via Path(__file__).resolve().parents[3] — they don't survive the cross-repo split, and the existing structural assertions on generator output cover the wire shape. Why: ops repo already hosts the noetl k8s deploy automation playbook + has its own ci/manifests/ dir; noetl/ci/manifests/ was a parallel copy that was bootstrapping debt. Scope B (consolidating the rest of repos/noetl/ci/manifests/ into ops + updating development/noetl.yaml to drop $NOETL_REPO refs) is a separate larger handoff round, queued. Out-of-phase: noetl/ops wiki not yet created — user mentioned wanting it as a sibling of noetl/noetl wiki, blocked on a one-time UI step to create the first page so the .wiki.git repo materializes.

## Actions
-

## Repos
-

## Related
-
