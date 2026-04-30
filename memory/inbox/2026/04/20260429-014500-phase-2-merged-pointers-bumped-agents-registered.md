# Phase 2 merged + pointers bumped + lifecycle agents registered

## What landed

- **noetl/noetl#394** merged. SHA on main: `029061de`.
- **noetl/ops#15** merged earlier in the session. SHA on main: `c9b81ec`.
- ai-meta commit `95e77db` bumps both submodule gitlinks in a single
  `chore(sync)` commit.

## On-kind catalog state after registration

```
automation/agents/kubernetes/lifecycle/deploy     v1  catalog_id 615416391922877342
automation/agents/kubernetes/lifecycle/undeploy   v1  catalog_id 615416392350696351
automation/agents/kubernetes/lifecycle/redeploy   v1  catalog_id 615416392627520416
automation/agents/kubernetes/lifecycle/restart    v1  catalog_id 615416392845624225
automation/agents/kubernetes/lifecycle/status     v1  catalog_id 615416393172779938
automation/agents/kubernetes/lifecycle/discover   v1  catalog_id 615416393466381219
mcp/kubernetes                                    v1  catalog_id 615416393701262244
```

## Open question — Mcp resource kind reported as `playbook`

The catalog register response for `mcp_kubernetes.yaml` came back with
`"kind":"playbook"` even though the file declares `kind: Mcp`.
Suspect cause: the CLI's `catalog register` (`repos/cli/src/main.rs`,
`fn register_resource`) appears to always pass `resource_type:
"Playbook"` for `.yaml` files instead of sniffing the YAML's own
`kind:`. If the catalog actually persisted it as `playbook`, the next
`POST /api/mcp/mcp/kubernetes/lifecycle/status` will 400 with
"expected mcp" because `fetch_mcp_resource` in the noetl server
explicitly checks `kind.lower() == "mcp"`.

Verify with:

```
noetl catalog get mcp/kubernetes
```

If the persisted kind is wrong, fix lives in `repos/cli` —
register_resource should parse the YAML, read `kind:`, and pass it
through (with the Mcp casing the catalog expects).

## Phase 2 production rollout — staged

Default `NOETL_AUTH_ENFORCEMENT_MODE=skip` so the freshly bumped kind
cluster keeps working unchanged. To turn enforcement on:

1. Populate `auth.playbook_permissions` for each lifecycle agent path
   (and the runtime agent path) — at minimum, grant `can_execute=true`
   to whatever role the GUI users belong to.
2. Set `NOETL_AUTH_ENFORCEMENT_MODE=advisory` on the noetl deployment.
   Tail logs for "advisory: would deny" warnings; populate any missing
   permissions.
3. Flip to `enforce` once the warnings dry up.

## Pending follow-ups

- Mcp-kind auto-detect bug (above) — file an issue / open a CLI PR if
  confirmed.
- gui PR #17 stranded commit `a8d16c2` (polling epoch + empty-JSON
  guards) — small cherry-pick.
- Mcp tab + Add-MCP wizard in the GUI (Phase 4 follow-up).
- Terminal-side `playbooks` listing pagination/filter (issue #37).

Tags: noetl, mcp, auth, phase-2, phase-3, pr-394, pr-15, pointers
