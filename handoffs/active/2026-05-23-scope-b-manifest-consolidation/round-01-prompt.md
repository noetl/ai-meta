---
thread: 2026-05-23-scope-b-manifest-consolidation
round: 1
from: claude
to: claude
created: 2026-05-23T19:15:00Z
status: open
expects_result_at: round-01-result.md
---

# Scope B — consolidate ci/manifests/ into noetl/ops

> **Predecessor:** Scope A (closed) moved the new Phase 4 manifests
> (`keda/`, `nats-supercluster/`) from `noetl/ci/manifests/` to
> `ops/ci/manifests/`. This round finishes the job for the
> remaining 11 directories that still live in both repos and have
> been drifting.

The goal: `noetl/noetl` no longer has a `ci/manifests/` directory.
`noetl/ops` is the single source of truth for operational manifests,
and `ops/automation/development/noetl.yaml` references manifests via
local paths — no more `$NOETL_REPO/ci/manifests/...`.

## Current divergence (audit done at handoff-open time)

```
$ diff -rq repos/noetl/ci/manifests repos/ops/ci/manifests | head -30
```

### Files that differ in content

| Path | Action |
|---|---|
| `clickhouse/README.md` | Pick the noetl version (likely more recent). Inspect first. |
| `gateway/README.md` | Pick noetl version. |
| `gateway/configmap-ui-files.yaml` | Pick noetl version. |
| `gateway/regenerate-ui-configmap.sh` | Pick noetl version. |
| `jupyterlab/README.md` | Pick noetl version. |
| `jupyterlab/configmap.yaml` | Pick noetl version. |
| `nats/README.md` | Pick noetl version (single-node, unrelated to supercluster). |
| `noetl/configmap-server.yaml` | Pick noetl version (Phase 1/2/3 envs). |
| `noetl/configmap-worker.yaml` | Pick noetl version (Phase 1/2/3 envs). |
| `noetl/rbac.yaml` | Pick noetl version. |
| `noetl/server-deployment.yaml` | Pick noetl version. |
| `noetl/worker-deployment.yaml` | Pick noetl version. |
| `postgres/config-files.yaml` | Pick noetl version. |
| `postgres/deployment.yaml` | Pick noetl version. |
| `qdrant/README.md` | Pick noetl version. |

For each diff: **read the diff first**. The noetl version is the
hot path that ops/automation/development/noetl.yaml consumes
today, so it represents current production-ish reality. The ops
version may carry GKE / production tweaks worth preserving — if
the diff shows ops adding something material (annotations,
toleration, etc.), merge rather than replace.

### Files only in noetl/ci/manifests/ (must be copied to ops)

- `noetl/configmap-outbox-publisher.yaml`
- `noetl/configmap-projector.yaml`
- `noetl/outbox-publisher-deployment.yaml`
- `noetl/projector-service.yaml`
- `noetl/projector-statefulset.yaml`
- `noetl/worker-metrics-service.yaml`

These are Phase 2 / Phase 6 artifacts added during the v2-spec
work and never landed in ops. Copy verbatim.

### Files only in ops/ci/manifests/ (stay; nothing to do)

- `gui/` — ops-only deployment (web UI)
- `keda/` — moved in Scope A; stays
- `nats-supercluster/` — moved in Scope A; stays
- `rustfs/` — ops-only experimental storage backend
- `seaweedfs/` — ops-only experimental storage backend

## Consumer playbook update

`repos/ops/automation/development/noetl.yaml` has ~70 references
to `$NOETL_REPO/ci/manifests/...`. After consolidation, all of
those become local `ci/manifests/...` paths (no `$NOETL_REPO`
prefix). `$NOETL_REPO` itself stays — it's still used for
non-manifest things like `Dockerfile` paths.

`repos/ops/automation/setup/bootstrap.yaml` already uses local
paths — no change.

`repos/ops/automation/test/pagination-server.yaml` already uses
local paths — no change.

## Phases

### Phase A — drift check + audit (no remote writes)

1. Re-run `diff -rq repos/noetl/ci/manifests repos/ops/ci/manifests`
   to confirm the divergence inventory above. Capture anything new.
2. For each differing file, read both versions side-by-side. Decide:
   **prefer noetl version**, **prefer ops version**, or **merge**.
3. For the only-in-noetl files, confirm they make sense in ops
   (the projector StatefulSet etc. should join the `noetl` dir
   of ops/ci/manifests/).
4. Confirm no third consumer references `$NOETL_REPO/ci/manifests/`
   outside the three known playbooks. `grep -rn '$NOETL_REPO' repos/ops/`.

### Phase B — ops branch: merge + add files

5. Branch `repos/ops`: `kadyapam/scope-b-manifest-consolidation`.
6. **For each differing file**: copy from `repos/noetl/ci/manifests/`
   over to `repos/ops/ci/manifests/`. If the audit said "merge",
   do the merge manually preserving ops-side tweaks.
7. **For each only-in-noetl file**: copy to the matching path in
   `repos/ops/ci/manifests/`.
8. Update `repos/ops/automation/development/noetl.yaml`: replace
   every `$NOETL_REPO/ci/manifests/...` with the local
   `ci/manifests/...` path. Be careful — there may be other
   `$NOETL_REPO/` uses (Dockerfile paths, source paths). Only
   the `ci/manifests/` references change.
9. Commit + open ops PR.

### Phase C — noetl branch: delete + breadcrumb

10. Branch `repos/noetl`: `kadyapam/scope-b-drop-ci-manifests`.
11. `git rm -r ci/manifests/` — drop the entire directory.
12. Search for any remaining noetl-repo references to `ci/manifests/`
    (probably none, but check tests, CI configs, docs).
13. Add a top-level note in `repos/noetl/README.md` or a stub
    `ci/manifests/MOVED.md` (decide which is friendlier) noting
    the move + linking to `noetl/ops/ci/manifests/`.
14. Commit + open noetl PR.

### Phase D — wiki + agents-rule updates

15. Update `repos/noetl-wiki/`:
    - Find any link to `https://github.com/noetl/noetl/blob/main/ci/manifests/...`
      and repoint at `noetl/ops`.
    - Confirm the existing rule-0 callout in
      `noetl/core/runtime/keda.md` and `nats_supercluster.md`
      still reads correctly.
16. Update `repos/noetl-ops-wiki/`:
    - Add a `Home.md` mention that all NoETL operational
      manifests now live exclusively in this repo.
17. Update `agents/rules/ops-deploy.md` to reflect the new shape:
    operational manifests are exclusively at
    `repos/ops/ci/manifests/`; the `$NOETL_REPO/ci/manifests/`
    pattern is dead.
18. Commit each wiki + the rule update.

### Phase E — tests / smoke

19. Sanity check the noetl test suite — running `pytest
    tests/core/runtime/ -q` should still pass (no live manifest
    dependency).
20. Read through the updated `development/noetl.yaml` and grep for
    any leftover `$NOETL_REPO/ci/manifests/` references. Should
    be zero.
21. Optional: dry-run `noetl run automation/development/noetl.yaml
    --runtime local --set action=render` from the ops repo to
    confirm the playbook still parses. (Skip if the playbook
    doesn't have a render action; otherwise just python-parse
    the YAML to confirm validity.)

### Phase F — open PRs, gate on `merge scope b`

> ***Run only after explicit human go-ahead. Wait phrase: `merge scope b`.***

22. Push both branches.
23. Open ops PR: `feat(manifests): absorb noetl ci/manifests/
    consolidation`.
24. Open noetl PR: `chore(manifests): drop ci/manifests/ — moved
    to noetl/ops`. **Mark with explicit "depends on noetl/ops#NNN".**
25. **Merge ops PR first** (so the manifests exist in their new
    home before noetl deletes them).
26. **Then merge noetl PR.**
27. Bump ai-meta pointers (repos/noetl, repos/ops, repos/noetl-wiki,
    repos/noetl-ops-wiki) in one ai-meta commit.
28. Archive handoff thread.
29. Drop memory entry.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt says
  so. Phase F is the only step that pushes, gated by
  `merge scope b`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- **Manifest divergence is a real risk.** Per-file audit before
  copying; don't blanket-replace. If ops version has GKE-specific
  or production tweaks, merge rather than overwrite.
- **`development/noetl.yaml` is hot code.** Even one stale
  `$NOETL_REPO/ci/manifests/` path will silently fail at deploy
  time. Grep-verify post-edit.
- Live kind cluster state — the existing supercluster + KEDA pods
  remain unaffected by file moves (kubectl doesn't care which
  git repo the YAML came from). No need to redeploy.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.

## Out of scope

- The noetl-wiki's full audit for `ci/manifests` link rot. We
  fix the obvious ones; a separate sweep can handle the rest.
- Migrating `repos/ops/automation/setup/bootstrap.yaml` or
  `test/pagination-server.yaml` — they already use local paths.
- The catalog-routing design round.
- Any new functionality. This is pure consolidation +
  cleanup.

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.
