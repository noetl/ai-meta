---
thread: 2026-07-14-shastara-org-gcp-provision
round: 7
from: claude
to: user
created: 2026-07-14T05:30:00Z
in_reply_to: round-06-prompt.md
status: partial
---

# Round 7 — Phase B STAGE 1 complete: guard implemented, built, proven (NO cloud writes)

Phase B is authorized (`implement provider tool`). Per your staging + my own
"confirm the 10 project IDs first" prerequisite, this is **Stage 1 only** — the
tool/guard work and its proof, with **zero cloud writes**. Stage 2 (folders)
follows in the next message; Stage 3 (projects) will **HALT** for your explicit
ID confirmation.

You chose **local dev-build now** (vs. full crates.io release flow). So: guard
implemented + built into a working `noetl 4.18.0`, proven against the real binary
and real Google (read-only); the formal crates.io release is a tracked follow-up.

## What shipped (two committed branches, not pushed)

**`noetl-tools` — branch `feat/provider-org-guard` @ `7d3abfa`** (version
3.25.0 → **3.26.0**):
- `GuardSpec { require_org, require_org_display_name, require_billing_account }`
  + optional `guard` field on `ProviderSpec`.
- `enforce_guard_offline()` — structural, **no-network** refusal fired in
  `run_spec` before any request is built or credential minted, so it protects
  dry-run / report / adopt / destroy / apply alike. Refuses if any input
  references an org or billing account other than the pinned one.
- `google.cloudresourcemanager.organizations.get` action (read-only) — backs the
  live check and is callable directly.
- `verify_guard_live()` — apply-mode read-only GETs asserting the pinned org's
  `displayName` and the billing account's `parent == require_org`.
- **8 new tests, 63 provider tests green, clippy clean.** Tests:
  `guard_wrong_org_id_refused_offline`, `guard_correct_org_id_passes_offline`,
  `guard_wrong_billing_account_refused_offline`, `guard_absent_is_noop`,
  `organizations_get_builds_read_only_url`, `enforce_guard_offline_unit`,
  `guard_live_display_name_mismatch_refused` (wiremock),
  `guard_live_display_name_match_proceeds` (wiremock).

**`noetl-cli` — branch `feat/provider-org-guard` @ `29ab087`** (cli 4.16.0 →
**4.18.0**, executor 0.7.0 → **0.8.0**):
- `guard` wired through `Tool::Provider` (playbook.rs enum) + the executor
  `tools_bridge` config assembly + the `playbook_runner` render path, so
  `noetl exec --runtime local` passes the guard to the tool.
- Re-pinned `noetl-tools 3.25 → 3.26`. **Version-bump discipline honored:** the
  executor's public `Tool::Provider` surface changed (added `guard`), so
  executor bumped 0.7.0 → 0.8.0 and the bin dep re-pinned `"0.7" → "0.8"` — this
  is exactly the `publish-crate` silent-skip trap you flagged; the bump makes the
  released surface carry the guard.

**Local dev-build recipe** (documented; the built binary is
`noetl 4.18.0`): the cli workspace Cargo.toml carries a local-only
`[patch.crates-io] noetl-tools = { path = <tools worktree> }` at build time
(stripped from the committed branch — it's a build aid, not release content). The
**formal release follow-up**: publish noetl-tools 3.26.0 → bump/publish
noetl-executor 0.8.0 → publish noetl-cli 4.18.0, via PR/CI, then drop the patch.

## Proof — the wrong-target guard REFUSES (real binary, real Google)

**Offline (structural, no network):**
```
WRONG org (adiona 103794563683):
  Error: org guard REFUSED: action "…folders.ensure" targets
  organizations/103794563683 but require_org pins organizations/561323743912;
  no request built, no network call
RIGHT org (561323743912): plans cleanly, exit 0.
```

**Live (real Google, read-only GET, NO write):** apply-mode `folders.ensure`
against the real org with a deliberately-wrong `require_org_display_name`:
```
  Error: org guard REFUSED (live): organizations/561323743912 displayName is
  "shastaratech-org" but require_org_display_name pins "WRONG-NAME-not-shastaratech"
```
Then verified read-only: **folders under org = <NONE>** — the refusal wrote
nothing. (Also confirms a clean slate for Stage 2.)

Both layers proven end-to-end with the built binary; the live-refusal *logic* is
additionally locked by the `guard_live_display_name_mismatch_refused` wiremock
unit test.

## Also verified in Stage 1

- **`by-display-name` parent resolution is ABSENT** in 3.25/3.26 → project
  creation is **strictly two-phase**: create folders → capture numeric ids →
  create projects with `parent: folders/<id>`. Stage 4 will thread the ids.
- **`adopt`/`reconcile` present** → no new tool code for the two existing
  projects' adopt path.
- **ADC identity re-confirmed** as the shastaratech owner, sees **one org**.

## What did NOT happen (Stage-1 boundary)

- **No cloud writes.** Every guard proof was dry-run, a read-only GET, or a
  refusal that wrote nothing. No folder, project, IAM binding, billing link, or
  API enablement created.
- **No crates.io publish, no PRs pushed, no ai-meta pointer bump** — the two
  branches are local; the release is the tracked follow-up.
- **No user `noetl` overwrite** — the guarded binary lives at its build path +
  a scratch copy; the system `noetl` (2.17.0) is untouched.

## Next: Stage 2 (folders) — proceeding

Creating the 5 folders under `561323743912` via a `kind: provider` playbook with
the guard block, `reconcile: enforce`, and ADC auth — folders are deletable, the
safe first real write. Report follows. **Stage 3 (projects) HALTS for your
explicit confirmation of all 10 project IDs.**

## Manual escalation / follow-ups

- **Formal crates.io release** of noetl-tools 3.26.0 + executor 0.8.0 + cli
  4.18.0 (PR/CI) — deferred; the local dev-build carries the guard now.
- `projects.iam.ensure_binding` still absent — not needed for the declared plan.
- `provider_cli` (`noetl provider adopt`) guard wiring — a Stage-4 item; it
  routes through `to_tools_config` which now carries `guard`, so a guard in the
  resource's tool block flows through, but the adopt verbs don't yet inject a
  guard from a flag. Assessed at Stage 4.
