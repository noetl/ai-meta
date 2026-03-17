# noetl pr266 follow-up fixes landed
- Timestamp: 2026-03-17T05:58:57Z
- Author: Kadyapam
- Tags: noetl,pr266,ahm-4280,ahm-4281,ahm-4282,ahm-4283,ahm-4284,memory

## Summary
Implemented and pushed noetl commit 78219783 on branch kadyapam/ahm-4280-4284-runtime-hardening. Fixes include active-claim cache TTL clamped to claim lease, Settings NATS_SUBJECT alias correction, expanded WorkerSettings numeric coercion coverage, and delayed NAK parsing guards for non-finite/oversized delays. Added targeted tests in tests/api/test_active_claim_cache.py, tests/core/test_nats_command_subscriber.py, and tests/core/test_config_settings.py; focused suites pass.

## Actions
-

## Repos
-

## Related
-
