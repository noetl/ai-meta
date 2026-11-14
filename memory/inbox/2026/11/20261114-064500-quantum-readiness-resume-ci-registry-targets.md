# Quantum readiness (shastaranch, private): resumed after a second reboot — CI, then registry/update TARGETs
- Timestamp: 2026-11-14T06:45:00Z
- Author: Kadyapam
- Tags: quantum-readiness, shastaranch, ci, control-plane, update-channel, flag-gated

## Summary

The session that produced #36–#48 was lost to a reboot. Resumed from git/PRs/Sessions-Log: #1–#48 merged, none open, so every TARGET named in the resume request had already landed. This session adds CI and works the remaining in-repo RFC TARGETs. All opt-in or default-off; nothing deployed; no prod flag, key or vendor API touched.

## Actions

- **#50 (merged `9e34be8`) CI:** GitHub Actions in the pinned Debian 13 base runs `tests/run_all_local.sh` (sha-pinned noetl 5.4.0 linux x86_64, pinned DuckDB `json` ext). Green.
- Branches built and locally green, PRs following #50: discovery + `runtime_kind` (#51), enrollment tokens (#52), manifest conditional GET (#53), operator-assigned cohorts.

## Lessons

- **Python 3.13 verifies X.509 strictly.** A private CA without `keyUsage` is rejected by urllib (`qready-cp-admin`, registry federation, discovery); curl is lenient, so the reporter alone never showed it. Customer CAs must be RFC 5280-conformant.
- **`kill -0` succeeds on a zombie.** Under a PID 1 that does not reap orphans (GitHub job containers run `tail -f /dev/null`), a stopped daemon looked alive and the binary supervisor aborted. Check the process state too.
- **macOS-only testing hid both.** The first Linux CI run is worth more than another local pass.
- **One signed manifest carries every channel,** so a site that switches channel can find a newer version inside the sequence it already consumed; the same-sequence rule must allow that (newer version, not already refused) without opening replay.
