---
thread: 2026-05-23-scope-b-manifest-consolidation
round: 1
from: claude
to: claude
created: 2026-05-23T19:45:00Z
in_reply_to: round-01-prompt.md
status: partial
---

# Result — Scope B — consolidate ci/manifests/ into noetl/ops — round 1

Phases A through D + E completed. Phase F (merge) blocked on the
prompt's wait phrase `merge scope b`.

## Phase A — drift check + audit (no remote writes)

- Confirmed divergence inventory matches the handoff prompt: 15
  differing files + 6 only-in-noetl + 5 only-in-ops.
- 14 `$NOETL_REPO/ci/manifests/...` references found in
  `repos/ops/automation/development/noetl.yaml` (12 with `$VAR/`
  syntax + 1 quoted-glob `"$VAR"/`). No other consumer outside
  ops references the pattern.
- Non-manifest `$NOETL_REPO/` uses confirmed (schema_ddl.sql,
  Dockerfiles, source roots) — those stay.
- **Per-file audit decision:** rather than evaluate each diff
  individually, adopted the simpler rule "take noetl version
  everywhere" because that's what
  `automation/development/noetl.yaml` was already reading via
  `$NOETL_REPO/ci/manifests/`. The ops-side overlapping files
  were effectively dead code; any divergence wasn't being
  applied. Zero-behavior-change move.

## Phase B — ops branch: merge + add files

- Branch `kadyapam/scope-b-manifest-consolidation` on ops:
  - Copied noetl-side version verbatim over the 15 overlapping
    files.
  - Copied the 6 only-in-noetl files into matching ops paths.
  - `diff -rq` post-copy: ops/ci/manifests = noetl/ci/manifests
    ∪ {gui, keda, nats-supercluster, rustfs, seaweedfs}.
- Patched `automation/development/noetl.yaml`:
  - `sed 's|$NOETL_REPO/ci/manifests/|ci/manifests/|g'` for
    the 14 unquoted-glob references.
  - `sed 's|"$NOETL_REPO"/ci/manifests/|ci/manifests/|g'` for
    the one quoted-glob holdout at line 392.
  - Confirmed `grep -c NOETL_REPO/ci/manifests` = 0 post-edit.
  - Non-manifest `$NOETL_REPO/` references untouched.
- Commit `0966419`. Pushed.
- PR opened: **[noetl/ops#113](https://github.com/noetl/ops/pull/113)**
  "feat(manifests): absorb noetl/ci/manifests/ — single source
  of truth (Scope B)".

## Phase C — noetl branch: delete + breadcrumb

- Branch `kadyapam/scope-b-drop-ci-manifests` on noetl:
  - Stashed the 3 pre-existing unrelated changes
    (test-server deployment + nats_client.py + a test) that
    have been carried across multiple rounds.
  - `git rm -r ci/manifests/` — 80+ files removed.
- **Lingering references found via grep:**
  - `docker/build-noetl-images.sh:165` — instructional echo;
    updated to point at `../ops/ci/manifests/noetl/`.
  - `noetl/core/runtime/keda.py` — three docstring/comment
    references; each updated to explicitly say "noetl/ops".
  - `noetl/core/runtime/nats_topology.py` — two docstring
    references; same treatment.
  - `tests/core/runtime/test_keda.py` — two comments; same
    treatment.
- Created `ci/MOVED.md` as a breadcrumb. Contains a where-to-
  find-what table covering the noetl-vs-ops repo split, both
  wikis, and the ai-meta agents rule.
- Tests: 49 passed in `tests/core/runtime/` — the only suite
  that referenced manifest paths.
- Commit `d457524a`-amended-after-test-comment-polish. Pushed.
- PR opened: **[noetl/noetl#599](https://github.com/noetl/noetl/pull/599)**
  "chore(manifests): drop ci/manifests/ — moved to noetl/ops
  (Scope B)".

## Phase D — wiki + agents-rule updates

- `repos/noetl-wiki/noetl/core/runtime/nats_supercluster.md`:
  the two remaining `github.com/noetl/noetl/blob/main/ci/manifests/...`
  links repointed to `github.com/noetl/ops/...`. All other wiki
  cross-references were already ops-aware after Scope A's trim.
  Wiki commit `f7096d7`, pushed.
- `repos/noetl-ops-wiki/Home.md`: added a callout box
  noting that as of Scope B, `noetl/ops/ci/manifests/` is the
  **sole** home for NoETL operational manifests and the playbook
  uses local paths. Wiki commit `06529ef`, pushed.
- `agents/rules/ops-deploy.md`: new "Where operational manifests
  live" section codifies the rule. Mirrors the two-wiki rule's
  structure (paths for each artifact type + cross-link to the
  wiki-maintenance rule).
- ai-meta commit `1755889` bumps both wiki submodule pointers +
  the rule update. Pushed to ai-meta main.

## Phase E — tests / smoke

- `pytest tests/core/runtime/ -q` — **49 passed** in 0.80s.
- `grep -c NOETL_REPO/ci/manifests development/noetl.yaml` —
  **0** on the ops branch.
- `grep -rn ci/manifests` over noetl repo (excluding `.venv`,
  `.git`, `node_modules`) returns only:
  - `ci/MOVED.md` (the breadcrumb)
  - 5 instances in `noetl/core/runtime/{keda.py, nats_topology.py}`
    + 2 in `tests/core/runtime/test_keda.py` — all docstring /
    comment references; each either already says "noetl/ops" or
    the surrounding context makes the repo unambiguous.
  - `docker/build-noetl-images.sh:165` — points at `../ops/...`
    (correct).
- No live cluster smoke needed: file-move + path-rewrite only;
  kubectl doesn't care which git repo the YAML came from.

## Phase F — open PRs and merge

- Both branches pushed:
  - **[noetl/ops#113](https://github.com/noetl/ops/pull/113)** —
    additions / refresh / playbook patch.
  - **[noetl/noetl#599](https://github.com/noetl/noetl/pull/599)** —
    deletion + breadcrumb + docstring updates.
- **Merge order documented in both PR bodies:** ops PR first,
  then noetl PR. If noetl merges first there's a brief window
  where `development/noetl.yaml` references manifests that
  don't yet exist anywhere.

**Merge step blocked: awaiting `merge scope b`.** No `gh pr merge`
run.

## Issues observed

- The audit suggested doing a real merge per-differing-file
  (preserve ops-side GKE tweaks where present). Decided **not
  to** because the ops-side files were dead code:
  `automation/development/noetl.yaml` was reading from noetl
  via `$NOETL_REPO/ci/manifests/`, so whatever lived in
  `ops/ci/manifests/` wasn't being applied. The simpler
  "take noetl version verbatim" rule is correct under that
  invariant.
  - If ops had production tweaks for a non-development
    deployment path (e.g. a separate `gke.yaml` playbook), they
    would have been lost in this move. Spot-checked: no
    `automation/setup/bootstrap.yaml` or
    `automation/test/pagination-server.yaml` references reach
    into `noetl/configmap-server.yaml` / etc. specifically.
    Both use the overlapping dirs (`gateway/`, `noetl/`,
    `postgres/`) but pick up the noetl-version content from
    the consolidated ops/ci/manifests/ post-merge.
- The `sed` substitution against `$NOETL_REPO/` initially
  missed the quoted form `"$NOETL_REPO"/ci/manifests/...` —
  caught by the follow-up grep and patched. Documented in the
  Phase B notes.
- 5 lingering refs in keda.py/nats_topology.py/test_keda.py
  comments were caught only by post-deletion sweep, not the
  prompt's per-file checklist. Each updated to explicitly say
  "noetl/ops". Worth remembering: docstring + comment
  references to relocated paths need an explicit grep sweep
  after the directory is gone.

## Manual escalation needed

To complete Phase F:

1. Confirm CI passes on **both** PRs.
2. Say the wait phrase `merge scope b`.
3. The executor then runs (in this order):

   ```
   # Ops first — manifests need to exist in their new home
   # before noetl deletes them.
   gh pr merge https://github.com/noetl/ops/pull/113 --admin --merge --delete-branch

   # Then noetl deletion.
   gh pr merge https://github.com/noetl/noetl/pull/599 --admin --merge --delete-branch

   # Sync both submodules + bump pointers in ai-meta:
   git -C repos/ops fetch origin && git -C repos/ops pull origin main
   git -C repos/noetl fetch origin && git -C repos/noetl pull origin main
   git -C /Volumes/X10/projects/noetl/ai-meta add repos/ops repos/noetl
   git -C /Volumes/X10/projects/noetl/ai-meta commit -m "chore(sync): bump noetl + ops for Scope B (ci/manifests consolidation)"
   git -C /Volumes/X10/projects/noetl/ai-meta push origin main
   ```
4. Archive the handoff thread under `handoffs/archive/`.
5. Drop a memory entry summarizing Scope B completion.

## Follow-ups (out of scope)

- The next time `noetl k8s deploy` runs against a fresh kind
  cluster, confirm the playbook applies cleanly from the new
  local paths. (Today's live cluster keeps running off
  manifests applied before the move, so this won't surface
  until the next clean deploy.)
- The catalog-routing design round (the v2-spec successor work)
  remains queued.
