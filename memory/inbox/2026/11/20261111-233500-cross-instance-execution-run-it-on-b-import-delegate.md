# Cross-instance execution: "run it on B" + sub-playbook import (#548, RFC §12)
- Timestamp: 2026-11-11T23:35:00Z
- Author: kadyapam (Claude session)
- Tags: catalog,cross-instance,remote-exec,pinning,server,tools,worker,cli,kind,flags-off,rfc-548

## Summary
A playbook on instance A can call a playbook that instance B owns, by catalog reference. It can either delegate the run to B or import the definition and run it on A. The execution's version pin holds across the remote call. All of it is merged and released, with every flag OFF and nothing on prod.

**Reference forms**
- `noetl://<instance>/<path>[@<version>][#sha256:<digest>]`
- The import name is `peer/<instance>/<path>`.
- Step: `tool: { kind: playbook, path: "noetl://<B>/xc/target", remote: delegate, return_result: true }`

**Modes** (`remote:` on `kind: playbook`; `NOETL_CATALOG_REMOTE_MODE` is the default for steps that don't say)
- `import` (default): the body is verified against its digest and imported under `peer/<B>/…`, content-addressed and deduplicated, with the source reference kept. It runs on A's workers. A bare sub-playbook name inside `peer/<B>/…` resolves to `peer/<B>/<name>` (home-instance resolution), never a same-named local playbook.
- `delegate`: A asks B to run the exact digest A pinned, on B's workers. The requests are signed via the item-9 instance trust gate (`rt.instances.gate.admit`):
  - purpose `catalog.execute`: POST `/api/catalog/peer/execute`;
  - purpose `catalog.execution`: POST `/api/catalog/peer/execution`, which answers the origin instance only.
  - A's worker polls through A at `/api/catalog/remote/calls/{id}` and `/{id}/status`, so `return_result` / `result_step` are unchanged.
  - `delegate` is refused for dedup and batch execute.

**Version-pin-across-remote-call invariant**
- On A, `noetl.execution_remote_pin` holds the first answer a reference gets in an execution tree. It is first-writer-wins per root (INSERT … ON CONFLICT DO NOTHING, then reread). Every later call in the tree gets the same digest, in either mode and however the reference is spelled.
- On B, `noetl.catalog_remote_origin` keeps one pin per (origin instance, origin root). Every delegated run from that root shares it, so B's own sub-playbooks hold their version too. The pin is passed as `ExecuteRequest.pin_override` into `catalog_cas::resolve_execute`.
- A cached `peer/` import never outranks the owner in a new tree. It is used only when the owner can't answer (any error except a Validation error).
- Other new tables: `noetl.catalog_remote_call` and `noetl.catalog_remote_exec`. All four tables are created by best-effort DDL and then detected.

**Flags** (all OFF; all require `NOETL_CATALOG_CAS` + `NOETL_CATALOG_PINNING`)

| Flag | Side | Notes |
|---|---|---|
| `NOETL_CATALOG_REMOTE_CALLS` | caller | delegate also needs `NOETL_CATALOG_DISCOVERY` |
| `NOETL_CATALOG_REMOTE_MODE` | caller | `import` (default) or `delegate`; a bad value → 422 |
| `NOETL_CATALOG_REMOTE_SERVE` | owner | answers peers |
| `NOETL_CATALOG_REMOTE_SERVE_ALLOW` | owner | path globs; fails closed (unset = serve nothing) |

With the flags off, `/api/execute` is unchanged, except that `remote: delegate` returns 403 naming the flag.

**Releases** (merge commits, main CI green; nothing rolled, no prod flag)

| PR | Merge | Release | Rollback |
|---|---|---|---|
| noetl/server#579 | addcb53 | v3.161.0 | 3.160.0 |
| noetl/tools#119 | c2e75ee | v4.6.0 (crates.io) | 4.5.0 |
| noetl/worker#401 | d1c9584 | v6.15.0 (pins tools =4.6.0) | 6.14.0, or re-pin `=4.5.0` |
| noetl/cli#110 | 7e413aa | v6.4.0 | 6.3.0 |
| noetl/ops#379 | a800523 | — | — |
| noetl/ai-meta#551 | — | RFC §12 in `docs/rfc/distributed-playbook-catalog.md` | — |

**Kind proof: 50/50** (`ci/kind/e2e_catalog_remote_exec.sh`)
- B was a full second runtime: its own DB `noetl_b`, cmdbus writer, server, user and system workers, and ML-DSA-87 key. None of B's events reached A's DB.
- Delegate: v2 of both the target and B's leaf was registered on B between A's two calls. Both calls still ran v1 + v1 under one B pin. A fresh root ran v2.
- Import: v2 held across a mid-run v3, with the leaf home-resolved from B. A fresh root saw v3.
- Refusals: outside the allowlist → refused; bad mode → 422; delegate with the flag off → 403.
- Unit and integration tests:
  - server: 1354 lib tests, plus `tests/catalog_remote_postgres.rs` covering both sides of the pin, races, a refused conflicting digest, home resolution, and the cached-import fallback;
  - tools: 538;
  - worker: 1089;
  - cli: 106.

**Stale-import bug (found by kind at 49/50, fixed before merge)**
- A fresh import-mode root reused a stale cached `peer/` import of B's leaf left by an earlier tree, so delegate and import disagreed on the version.
- Fix (server commit "fix(catalog): a cached peer/ import never outranks the owner in a new tree"): the owner's answer wins, and the cached row is a fallback only.

**Runtimes**
- Distributed: REAL.
- CLI (`noetl run`) and daemon (`noetl serve`): no instance key or peer registry, so they can't call another instance. cli 6.4.0 refuses a remote reference by name instead of reporting "file not found".

## Actions
TARGET, still open:
- B pushes completion to A. Today A's worker polls every 2 s, with one signed request to B per poll.
- Cancelling A's run doesn't cancel the run delegated to B.
- Delegation in batch execute (refused today).
- The CLI and daemon calling another instance.
- B's pin anchors at B's first delegated call, not at A's root start.
- No ehgraph edge links A's call to B's execution.

Prod enablement is an explicit owner decision, one flag at a time. No flag is in any prod manifest.

## Repos
- noetl/server, noetl/tools, noetl/worker, noetl/cli, noetl/ops, noetl/ai-meta

## Related
- ai-meta#548 (umbrella), wiki Umbrella-Distributed-Playbook-Catalog, Sessions-Log 2026-11-11 (night)
- Kind gotchas: apply the A→B address rewrite before adding B's peer env, or B advertises to itself. Step results are in `call.done`, not `command.completed`.
- Housekeeping: the podman store filled up, and `podman image prune -f` removed dangling layers only (117 GB).
