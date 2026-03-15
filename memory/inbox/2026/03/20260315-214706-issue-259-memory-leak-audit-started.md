# issue-259-memory-leak-audit-started
- Timestamp: 2026-03-15T21:47:06Z
- Author: Kadyapam
- Tags: noetl,memory,issue-259,server,worker,storage,cache

## Summary
Created noetl issue #259 for Python memory leakage audit across server/worker. On branch codex/memory-leak-audit-initial, implemented first mitigation in TempStore: bounded LRU caches, centralized scope tracking in put(), scope untracking on eviction/delete, added tests (4 passed), and posted progress comments with branch+commit links.

## Actions
- Refreshed `ai-meta` and submodules (`git pull --ff-only`, `git submodule sync --recursive`, `git submodule update --init --recursive`).
- Opened issue `noetl/noetl#259` for server+worker Python memory leak audit.
- Added first runtime mitigation in `repos/noetl` commit `0e283ddf`:
- Bounded `TempStore` `_ref_cache` and `_memory_cache` with LRU eviction and env-configurable limits.
- Centralized scope tracking in `TempStore.put(...)` so worker-side `default_store.put(...)` refs are tracked too.
- Added scope untracking on cache eviction/deletion to prevent stale tracker-only references.
- Added regression tests in `tests/core/test_result_store_cache_tracking.py`.
- Ran `pytest tests/core/test_result_store_preview.py tests/core/test_result_store_cache_tracking.py -q` (`4 passed`).
- Posted issue progress comments with findings and branch/commit links.

## Repos
- `repos/noetl` branch `codex/memory-leak-audit-initial`
- `repos/noetl` commit `0e283ddf`
- `ai-meta` submodule pointer update pending to commit this memory entry + `repos/noetl` SHA bump

## Related
- Issue: `https://github.com/noetl/noetl/issues/259`
- Issue progress comment: `https://github.com/noetl/noetl/issues/259#issuecomment-4063961896`
- Issue progress comment: `https://github.com/noetl/noetl/issues/259#issuecomment-4063963122`
