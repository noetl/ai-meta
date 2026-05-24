# Scope B — ci/manifests fully consolidated into noetl/ops
- Timestamp: 2026-05-23T19:24:01Z
- Author: Kadyapam
- Tags: noetl,ops,ci-manifests,scope-b,consolidation,refactor,cross-repo

## Summary
Cross-repo refactor completing what Scope A started: noetl/ops/ci/manifests/ is now the SOLE home for NoETL operational manifests; noetl/noetl/ci/manifests/ is deleted and replaced with a ci/MOVED.md breadcrumb. PRs: noetl/ops#113 (absorption + automation/development/noetl.yaml patch, merge 3eca358) + noetl/noetl#599 (deletion + breadcrumb + docstring sweep, merge 65a02bf4) + noetl-wiki@f7096d7 (link fix) + ops-wiki@06529ef (Home callout). Audit: 15 overlapping files (took noetl version since that was what $NOETL_REPO/ci/manifests/ was deploying anyway = zero-behavior-change move) + 6 only-in-noetl files added to ops + 5 only-in-ops dirs preserved (gui, keda, nats-supercluster, rustfs, seaweedfs). automation/development/noetl.yaml patched: 15 $NOETL_REPO/ci/manifests/ refs (incl one quoted-glob variant) become local ci/manifests/ paths; non-manifest $NOETL_REPO/ uses (SQL, Dockerfiles, source roots) untouched. agents/rules/ops-deploy.md gains 'Where operational manifests live' section codifying the convention for future agents. ai-meta now references the canonical paths through three layers: ops-deploy rule + wiki-maintenance Rule 0 + ci/MOVED.md breadcrumb + docstrings in keda.py/nats_topology.py. Live kind cluster unaffected; same YAML being applied, just from a different git repo path. Stash at repos/noetl stash@{0} contains 3 pre-existing unrelated files carried across multiple rounds — surfaced for the user to triage.

## Actions
-

## Repos
-

## Related
-
