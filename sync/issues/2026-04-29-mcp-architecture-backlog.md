# MCP architecture backlog (2026-04-29 session)

After the 14-PR session that landed the catalog-driven MCP
architecture end-to-end (see
`memory/inbox/2026/04/20260429-060000-mcp-architecture-end-to-end-running.md`
for the full PR + verification log), these are the open
follow-ups. None are blocking; the architecture is live and
visible in the GUI on a local kind cluster as of this date.

## Tracking convention

Each item has a short id (the session task number where it
was first surfaced — TaskList numbers are ephemeral but the id
helps trace back through the inbox entries). When you start
work on one, either:

- create a feature branch and link the relevant PR back here,
  or
- promote it to a GitHub Issue against the right repo and
  delete the entry below once that issue exists.

---

## #37 — `playbooks` terminal listing pagination + filter

**Repo**: `noetl/gui`
**Severity**: quality-of-life

The terminal-prompt `playbooks` command dumps every catalog
entry in one shot. With a populated catalog (~40+ playbooks
including the new lifecycle agents) the output overflows
viewport. Add page-size + filter args:

```
playbooks --kind=playbook --limit=20 --since=24h
playbooks --search="lifecycle"
```

Existing `apiService.getPlaybooks()` and
`apiService.searchPlaybooks(rest)` already support filtering
on the server side; just plumb the args through and add an
`open` action chip at the bottom of the result that re-runs
with `--limit ×2`.

Lives in `repos/gui/src/components/NoetlPrompt.tsx`,
search for `verb === "playbooks" || verb === "catalog"`.

---

## #51 — Mcp tab + Add-MCP wizard

**Repo**: `noetl/gui`
**Severity**: feature work

The headline next feature. Now unblocked by:

- `kind: Mcp` is honoured through the catalog (#395)
- DSL JSON schema (`noetl/core/dsl/playbook.schema.json`) for live
  validation in the wizard form (#396)
- register-time Pydantic validation (#397) — server rejects
  malformed Mcp YAML before it hits the catalog
- the curated `mcp_kubernetes.yaml` template to seed from

Shape:

1. Add a "Mcp" tab to the GUI's left rail (sibling to
   Catalog / Execution / Edit / Secrets / Travel / Users).
2. The tab lists registered Mcp resources as cards (one per
   row), each card showing the lifecycle verb chips and the
   current `discovery.tools_list_url` health.
3. "Add MCP server" button opens a wizard:
   - Step 1: paste a YAML or pick from a template (today
     just `mcp_kubernetes.yaml`; future templates live under
     `repos/ops/automation/agents/<provider>/templates/`).
   - Step 2: form-edit the workload knobs
     (`spec.deployment.namespace`, `image_tag`, `toolsets`,
     etc.) live-validated against `playbook.schema.json`.
   - Step 3: register + dispatch `lifecycle.deploy` in one
     submit. The dialog streams the deploy execution result
     inline; success closes the wizard and refreshes the tab.

Most of the form-rendering machinery already exists in
`PlaybookRunDialog.tsx` (the `_ui_schema` driven renderer).
Reuse those primitives for the wizard instead of building a
parallel form stack.

---

## #74 — GUI prompt: context-aware lifecycle verbs

**Repo**: `noetl/gui`
**Severity**: usability paper-cut

After `cd /mcp/lifecycle:redeploy`, typing `status` or `tools`
resolves to the global noetl health-check builtin (returns
`{"status":"ok"}`) or "unknown command" — not the
context-appropriate `lifecycle.status` agent for the parent
Mcp resource. The visual chips on the page work fine
(mouse-click goes through to the run dialog correctly), but
typing the verb name doesn't match what's visible.

Fix: in `NoetlPrompt.tsx`'s verb dispatch, when `cwd` matches
`/mcp/<name>` or `/mcp/lifecycle:<verb>`, the parent Mcp
resource's lifecycle verbs should shadow the global builtins.

Specifically: detect `isLifecycleVerb(verb)` (verb in
deploy/undeploy/status/restart/discover/redeploy) when the
cwd is an Mcp workspace, then route to the corresponding
`POST /api/mcp/<mcp_path>/lifecycle/<verb>` instead of
falling through to the global `getHealth()`.

---

## #78 — Bake mcp-server reader RBAC into the chart values

**Repos**: `noetl/ops` (lifecycle.deploy agent) ± upstream chart

The `extraClusterRoles` / `extraClusterRoleBindings` block in
`automation/agents/kubernetes/lifecycle/deploy.yaml`'s helm
values **didn't translate into actual RBAC objects** when
helm installed `kubernetes-mcp-server` chart v0.1.0. Manual
`kubectl apply` of the
`kubernetes-mcp-server-reader` ClusterRole + Binding is
required as a follow-up step (see step 8 of
`docs/operations/mcp-end-to-end-local-kind.md`).

Two paths:

A. **Look at the chart's actual values schema.** The chart
   may use a different key than `extraClusterRoles` — check
   `helm show values oci://ghcr.io/containers/charts/kubernetes-mcp-server --version 0.1.0`
   and update our values to match.

B. **Add an explicit `kubectl apply` step in lifecycle.deploy**.
   The agent's shell tool block has the RBAC YAML inlined and
   pipes it to `kubectl apply -f -` after the helm install
   completes. Loses some declarativeness but is robust to
   chart-values format changes.

Path A first, fall back to B if the chart's values block
doesn't actually support cluster-scoped RBAC the way our
deploy.yaml expects.

---

## #79 — `failed: True` despite a successful deploy

**Repo**: `noetl/ops` (most likely the lifecycle.deploy
agent's python end-step)

`POST /api/mcp/mcp/kubernetes/lifecycle/deploy` returns
`failed: True, completed: False, completed_steps: ["end",
"deploy"]` even when the helm install succeeded and the
kubernetes-mcp-server pod ends up Running. Diagnostic was
blocked by a terminal paste glitch (the `{k!r}` f-string bug
that intercepts when pasted into the user's shell).

To repro / diagnose:

```bash
EXEC_ID=<recent lifecycle.deploy execution_id>
curl -s "http://localhost:8082/api/executions/${EXEC_ID}/status?full=true" \
  > /tmp/exec.json
python3 -c "
import json
d = json.load(open('/tmp/exec.json'))
print('failed_step:', d.get('failed_step'))
print('error:', d.get('error'))
print('completed_steps:', d.get('completed_steps'))
v = d.get('variables', {})
for k in ('deploy', 'deploy_output', 'end'):
    if k in v:
        print('--- variables[' + k + '] ---')
        print(json.dumps(v[k], indent=2)[:2000])
"
kubectl -n noetl logs -l app=noetl-worker --tail=400 \
  | grep "${EXEC_ID}" | tail -20
```

Most likely cause: a `set -euo pipefail` line in the deploy
shell tripping on a downstream parsing assertion after the
helm install proper. Or the python end step parsing
`deploy_output` and reporting failure when it shouldn't.

---

## #80 — GUI prompt: support `&&` to chain commands

**Repo**: `noetl/gui`
**Severity**: paper-cut

`cd catalog && ls` returns:

```
usage: cd <catalog|editor|execution|credentials|travel|users>
```

…because the prompt parser dispatches verbs whole — it sees
the cd argument as the literal string `"catalog && ls"` and
none of the known catalog ids match. Fix: split on `&&`
(and probably `;`) before dispatching, then run each verb
in sequence stopping at the first non-zero result.

Lives in `repos/gui/src/components/NoetlPrompt.tsx`,
the input-handling section before `verb === "ls"` /
`verb === "cd"` / etc.

---

## Promote to GitHub Issues?

These are durable enough to live here (they're internal
cross-repo notes with full context). Promote any of them to
public GitHub issues if/when:

- you want external contributors to pick them up
- you want a public link to share
- the work is going to be a multi-PR thread that benefits
  from discussion threading

Otherwise, leave them here and reference this file from
inbox entries / commit messages as you knock items off.

## How to remove an item

When you ship a fix:

1. Reference this file in the PR body
   (`refs sync/issues/2026-04-29-mcp-architecture-backlog.md`)
2. After merge, edit this file to delete the item (or move
   it to a `# Closed` section at the bottom — append-only is
   fine, file size is cheap)
3. Add a short inbox entry tying it off:
   `memory/inbox/2026/MM/<date>-closed-<short-id>.md`

Tags: backlog, mcp, architecture, gui, ops, follow-ups
