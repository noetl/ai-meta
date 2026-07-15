---
thread: 2026-07-14-shastara-org-gcp-provision
round: 16
from: claude
to: user
created: 2026-07-15T03:15:00Z
in_reply_to: round-06-prompt.md
status: complete
---

# Round 16 — 4.18.0 published + fully verified; cli repo RELEASED and CLEAN

Recovered the interrupted release via `release-cli` workflow_dispatch (version was
already cut+tagged; the failure was a cosmetic post-publish step). All jobs green;
every acceptance test passed.

## Release cut
- semantic-release computed **noetl 4.18.0**; **noetl-executor 0.8.0** (manual bump).
- release-cli run 29384744824: verify-version, publish-crate, build-deb, 3×
  build-release-assets, github-release, update-homebrew-tap, update-apt-repo — all
  SUCCESS.

## crates.io — verified (sparse index + tarball, not green CI)
- **noetl-executor 0.8.0**: sparse index YES; tarball carries the provider
  `guard: Option<serde_yaml::Value>` on `Tool::Provider` (dead-surface trap
  cleared — the public surface really shipped). tools pin 3.26.
- **noetl 4.18.0**: sparse index YES; tarball version 4.18.0, executor dep present,
  `append_applied_fact` present.

## Published-binary round-trip — PASS
Downloaded the v4.18.0 darwin-arm64 release asset (not the worktree):
- `noetl exec --facts-out state.jsonl` (already-enabled service, noop) appended one
  masked JSONL fact (`…/youtube.googleapis.com`, verb:ensure, outcome:noop).
- `noetl provider orphans --facts-file state.jsonl --stack shastaratech-org-foundation`
  READ IT BACK: "owned per EHDB, no longer declared". dry-run appends nothing.

## apt + homebrew — PASS on BOTH distros
- `pool/main/noetl_4.18.0-1_amd64.deb` present; **dists/jammy AND dists/noble**
  Packages both index `Version: 4.18.0-1`. The #69 apt-token fix + #70 noble-dist
  fix HELD under a real release.
- homebrew `noetl/homebrew-tap` Formula/noetl.rb → `v4.18.0`, sha256 e816137f… —
  **sha MATCHES** the computed tag tarball.

## Tracking
- **#12 (state sink) CLOSED** with the published-binary round-trip evidence.
- **ai-meta#190** was already CLOSED (it's the executor-publish-fix, not apt);
  added a comment confirming executor 0.8.0 shipped the provider surface. apt
  acceptance (both distros) confirmed above.

## Process-guard recommendation (SEPARATE small PR — not bundled)
The whole publish was skipped because `@semantic-release/github`'s success step
threw on a bare `#69` cross-ref in the release commit. Propose setting
`successComment: false` (and `failComment: false`) for the `@semantic-release/github`
plugin in noetl/cli's semantic-release config, so a cosmetic commenting step can
never take down the release dispatch again. Low-risk config-only PR.

## ai-meta gitlink bumps — deferred
Not bumping repos/cli or repos/tools pointers: the ai-meta submodule state carries
a pre-existing half-finished staged downgrade; a clean gitlink bump belongs in a
separate focused change, not this session. The shipped crates (crates.io) are what
the shastara work consumes.

## cli repo status: RELEASED + CLEAN
noetl/cli main is at 4.18.0, published to crates.io + apt (both distros) + homebrew,
all verified. **The verb-rework session can branch off the new main.**

## Provisioning remainder (unchanged)
Billing 5/10 (account cap; quota-increase request is the user's). IAM complete
(one deviation declined). Everything else done.
