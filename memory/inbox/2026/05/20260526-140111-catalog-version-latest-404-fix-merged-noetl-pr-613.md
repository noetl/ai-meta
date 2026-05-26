# Catalog version=latest 404 fix merged — noetl PR #613
- Timestamp: 2026-05-26T14:01:11Z
- Author: Kadyapam
- Tags: noetl,inline-execution,catalog-fallback,pr-613,bug-fix,pointer-bump

## Summary
Phase D bug fix shipped. noetl PR #613 (435a0207 -> c0fb3b8d) changed _load_inline_child_playbook_from_catalog request body from {path,version:"latest"} to {path}. Server's /api/catalog/resource treats missing version as 'highest version row'. Release CI bumped to v2.102.1 (310accc8) — waiting for PyPI publish before rebuilding GKE image. Round B runner code is unchanged; this fix only enables the detector to evaluate real child playbook content instead of falling through to the filesystem placeholder. Tests: 40/40 in tests/tools/test_agent_executor.py incl. new regression test_load_inline_child_from_catalog_omits_version_field. Bumped repos/noetl pointer to 310accc8. Next: build inline-runner-v2 image, redeploy, flip enforce, re-run smoke playbook (catalog id 635314729543533052) to confirm meta.inlined_in_parent + meta.inline_mode=worker appear on child events. Then parent-cancel spot-check, then close handoff thread.

## Actions
-

## Repos
-

## Related
-
