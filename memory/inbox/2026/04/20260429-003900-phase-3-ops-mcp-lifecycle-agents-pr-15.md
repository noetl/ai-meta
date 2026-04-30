# Phase 3 — ops MCP lifecycle agent fleet (PR #15)

## What landed

[noetl/ops#15](https://github.com/noetl/ops/pull/15) on branch
`kadyapam/mcp-lifecycle-agents-phase-3`. Commit `50e9a14`. 7 files,
687 insertions.

New playbooks under `automation/agents/kubernetes/lifecycle/`:

| verb       | summary                                                                 |
|------------|-------------------------------------------------------------------------|
| `deploy`   | `helm upgrade --install` driven from `mcp_resource.spec.deployment.*`. Refuses if `kubectl current-context != workload.expected_kube_context` (default `kind-noetl`). |
| `undeploy` | idempotent `helm uninstall` + optional namespace delete (same context guard). |
| `status`   | read-only `kubectl get deploy,svc,pods` + curl `/healthz` from ephemeral `mcp-health-check` pod. |
| `restart`  | `kubectl rollout restart deployment/<release>` + wait. |
| `redeploy` | sub-playbook chain `undeploy` → `deploy` via `tool: kind: playbook` with `delete_namespace: true`. |
| `discover` | runs curl against in-cluster `/mcp/tools` from ephemeral `mcp-discover-curl` pod, parses tools list, returns `{added, removed}` diff. |

Plus the curated `kind: Mcp` template:

- `automation/agents/kubernetes/templates/mcp_kubernetes.yaml` — wires
  lifecycle / discovery / runtime / deployment blocks together. `tools: []`
  intentionally — discover populates it after first run.

## Design notes

- Every lifecycle agent ends with a `kind: python` step returning
  `{status, agent, verb, mcp_path, text}` so the `playbook.completed.result`
  event surfaces the shell stdout instead of a noop ack — same fix shape
  as ops#13 for the runtime agent.
- No new auth vocabulary: granting execute on each lifecycle path through
  the existing auth-as-playbook flow IS granting "may run lifecycle.<verb>".
- Image tag pinned at `v0.0.61`, chart at `oci://ghcr.io/containers/charts/kubernetes-mcp-server@0.1.0` —
  override per Mcp resource via `spec.deployment.image_tag` / `chart_version`.

## How it was pushed

Sandbox is allowlist-blocked from `github.com` (curl returns
`X-Proxy-Error: blocked-by-allowlist`); no `gh` CLI in sandbox. User
ran the commands directly in their host Terminal:

```bash
cd /Volumes/X10/projects/noetl/ai-meta && find .git -name '*.lock' -delete
cd repos/ops
git add automation/agents/kubernetes/lifecycle/ automation/agents/kubernetes/templates/
git commit -m "feat(agents): kubernetes MCP lifecycle agent fleet + curated Mcp template (architecture phase 3)"
git push -u origin kadyapam/mcp-lifecycle-agents-phase-3
gh pr create --repo noetl/ops --base main --head kadyapam/mcp-lifecycle-agents-phase-3 \
  --title "..." --body-file /Volumes/X10/projects/noetl/ai-meta/scripts/phase3_pr_body.md
```

Body file lives at `scripts/phase3_pr_body.md`. Launcher attempts
(`Phase3Push.app` + `phase3_push.command`) didn't open from Cowork's
`computer://` link — direct paste in Terminal worked first try.

## Next

- Watch PR #15 for Copilot review (likely: jinja defaults, ephemeral pod
  name collisions if two discovers race, hard-coded image tag).
- After merge: bump `repos/ops` gitlink in ai-meta + re-register the new
  agents in the kind cluster.
- Follow-ups already tracked: Phase 2 (gateway route-aware `check_access`
  for `/api/mcp/.../*`), Phase 4 follow-up (Mcp tab + Add-MCP wizard),
  stranded gui commit `a8d16c2`.

Tags: ops, mcp, lifecycle, kubernetes, helm, phase-3, pr-15
