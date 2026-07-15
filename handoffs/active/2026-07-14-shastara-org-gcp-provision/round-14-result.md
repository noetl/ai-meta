---
thread: 2026-07-14-shastara-org-gcp-provision
round: 14
from: claude
to: user
created: 2026-07-14T13:00:00Z
in_reply_to: round-06-prompt.md
status: partial
---

# Round 14 — 3.26.0 released+verified; cli sink PR open (HALT for relay)

## Release boundary 1 — noetl-tools 3.26.0 LIVE + VERIFIED
PR noetl/tools#91 (feat guard + 403 fix + LRO fix) → squash-merged → semantic-release
cut **3.26.0** (tag v3.26.0) → release-tools published. Verified on crates.io:
sparse index shows 3.26.0 AND the tarball carries all three changes (guard 32 hits,
`StatusCode::FORBIDDEN`, `poll_base`, `organizations.get`, version 3.26.0). Green CI
was not trusted — tarball content confirmed.

## Exec-wiring fast-follow — folded in + proven
`noetl exec --facts-out <path>` now persists facts on the provisioning path (not
just the verbs): `PlaybookRunner.with_facts_out`, shared `append_applied_fact`.
Proven on the built binary — an already-enabled service (noop) appends a
wrapped+masked fact; dry-run writes nothing.

## Hazard caught: branch base was behind main
The cli work branch was based on 4.16.0 — behind main's 4.17.0 + the apt-CI fixes
(#69 dead-token, #70 dist loop). A naive push would have REVERTED release.yml +
CHANGELOG. Rebased onto a fresh main base; final diff is 8 files (code +
Cargo.toml/lock) with **no release.yml/CHANGELOG touched**.

## cli PR — OPEN, NOT MERGED (HALT)
**noetl/cli#71** — guard wiring + git-backed state sink (+ exec `--facts-out`).
- executor 0.7.0 → **0.8.0** (Tool::Provider public surface changed — guard field;
  manual bump stops publish-crate skipping a stale executor).
- noetl-tools re-pinned 3.26; cli version left to semantic-release.
- Built against published 3.26.0; sink tests green; clean 8-file diff.
- **Version note:** semantic-release from 4.17.0 + feat → **4.18.0** (not 4.19.0).
  executor 0.8.0 + noetl publish TOGETHER in the one cli release (workspace
  publish-crate order: events → executor → noetl), so both verify after merge, not
  before.

Awaiting your merge-go. On merge: verify executor 0.8.0 + noetl 4.18.0 on crates.io
(sparse index + tarball), prove the round-trip on the PUBLISHED binary
(`noetl exec --facts-out` → `noetl provider drift --facts-file`), and confirm apt
serves 4.18.0 (first release since the #69 apt-token fix).

## Held
- cli PR #71 NOT merged. IAM grant NOT applied. Billing 5/10 (cap; quota request is yours).
