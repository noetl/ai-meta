---
thread: 2026-07-14-shastara-org-gcp-provision
round: 13
from: claude
to: user
created: 2026-07-14T12:15:00Z
in_reply_to: round-06-prompt.md
status: partial
---

# Round 13 — org IAM finalized (deviation accepted); state sink built

## (a) Org IAM — LEFT AS-IS, deviation recorded, #11 CLOSED
Did NOT apply `iam.securityAdmin → root` (redundant; root holds organizationAdmin
which supersets it). Both human admins already hold the full effective set. #11
closed with the accepted-deviation note; wiki Runbook §2.12 documents the
declared-vs-actual divergence so a future `drift` run treats it as accepted, not
unexpected.

## (b) State sink — BUILT (noetl-cli only), round-trip proven, NOT merged
Commit `41028b3` on `feat/provider-org-guard` (noetl-cli 4.18.0 → **4.19.0**):
- **`--facts-out <path>`** — appends the emitted `provider_fact` as one JSONL line
  (wrapped `{provider_fact:…}`) after a successful apply; **`planned`/dry-run not
  written**.
- **`load_facts` reads JSONL AND the array form** (`parse_facts_content`) —
  backward-compatible with `--facts-file`.
- **`mask_fact_identifiers`** — billing-account id + IAM member masked in the
  written fact (neither is a credential; policy-masked so a committed file stays
  clean).
- `adopt` appends on `--apply`.
- **Round-trip test passes:** append (masked) → JSONL read-back → fold →
  ownership; planned filtered; billing id masked. 2 new tests + suite green.
- **CLI-only** — no noetl-tools / executor surface change (verified).
- Scoped follow-up: wire `--facts-out` into `noetl exec` (the provisioning path)
  so converge-via-exec persists too — small add, next round. #12 updated.

**Not pushed as a PR yet** — it depends on noetl-tools 3.26.0 publishing first (CI
would fail against an unpublished dep). See the release plan.

## (c) noetl-tools 3.26.0 release plan (the two fixes must not strand)
The guard branch's unreleased 3.26.0 carries three real things the shastara work
depends on:
1. Wrong-org guard (feature).
2. `projects.ensure` 403-may-not-exist → absent→create (fix).
3. `services.enable` LRO poll host (fix).

**Recommended release order (each verified on crates.io — sparse index + tarball):**
1. **noetl-tools 3.26.0** — guard + both fixes. Release now; don't batch (the
   fixes are load-bearing for provisioning).
2. **noetl-executor 0.8.0** — guard wiring surface; re-pin tools 3.26.
3. **noetl-cli 4.19.0** — guard wiring + state sink; re-pin tools 3.26 + executor
   0.8. The sink PR opens here (after 1–2 publish, so CI builds).

Nothing is released yet (the whole chain has been a local dev-build). The release
needs your go per PR (push → CI → semantic-release → crates.io → verify). The two
fixes ride 3.26.0 — releasing it un-strands them.

## Provisioning state (unchanged from round 12)
Folders (5), projects (10), youtube-prod billing-linked, APIs baseline all 10 +
youtube full set, `shastara` adopted, `My First Project` deleted. Billing 5/10
(cap; 5 pending your quota-increase request). Org IAM complete.

## Held (as instructed)
- Sink PR **not merged** (not even pushed — pending the 3.26.0 release).
- IAM grant **not applied**.
