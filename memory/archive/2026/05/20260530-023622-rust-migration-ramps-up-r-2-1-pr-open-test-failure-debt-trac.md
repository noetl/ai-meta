# Rust migration ramps up: R-2.1 PR open + test-failure debt tracked + stale tasks resolved
- Timestamp: 2026-05-30T02:36:22Z
- Author: Kadyapam
- Tags: rust,arrow,r2-1,issue-30,tech-debt

## Summary
PR noetl/docs#174 (blueprint + Appendix H) merged; pointer bumped to dabbcf3. Started R-2.1 in parallel with PR noetl/cli#20 review: noetl/tools#2 adds arrow + arrow-ipc + arrow-flight v53 to noetl-tools with src/arrow_codec.rs (encode/decode helpers using Feather V2 IPC stream format, bytes round-trip with Python's ArrowIpcSharedMemoryCache without shape conversion). 3 new tests pass. Pre-existing test failure tracked as ai-task noetl/noetl#638 (test_batch_mirror_envelopes_feed_replay_state_projector ValueError on stage-1 — service.py:685 sorted(key=lambda row: int(row['stage_id']))). Stale tasks #12 (e2e fixtures credentials) confirmed already protected by .gitignore; #13 (google-places REDACTED NameError) likely covered by noetl/noetl@2fb6f1f9 sanitize fix. Both closed in session task list.

## Actions
-

## Repos
-

## Related
-
