# MCP architecture end-to-end on kind: pod Running, GUI showing it

## Visible victory state

```
$ kubectl -n mcp get all
pod/kubernetes-mcp-server-7d768c67cf-2zdc9   1/1   Running
service/kubernetes-mcp-server                 ClusterIP   10.96.221.30   8080/TCP
deployment.apps/kubernetes-mcp-server         1/1
```

`http://localhost:38081/` → GUI catalog browser → `cd /mcp/kubernetes`
→ click `pods` → MCP server returns real pod data through the friendly
run dialog. Every architectural phase wired through real cluster state.

## PRs merged this session

```
noetl/noetl#395  fix(catalog): YAML payload kind: is authoritative on register
noetl/noetl#396  chore(dsl): regenerate Playbook JSON schema from v10 Pydantic models
noetl/noetl#397  feat(catalog): validate Playbook/Agent payloads at register time
noetl/noetl#398  fix(catalog): preserve HTTPException status on /catalog/register
noetl/noetl#399  feat(docker): bake helm + kubectl into the noetl worker image
noetl/noetl#400  feat(tools): kind:shell executor in the distributed worker
noetl/noetl#401  feat(rbac): cluster RBAC for noetl-worker lifecycle-agent installs

noetl/ops#15     feat(agents): kubernetes MCP lifecycle agent fleet + curated Mcp template
noetl/ops#16     fix(agents): canonical NextRouter form for lifecycle agents
noetl/ops#17     fix(deploy): configurable podman machine name; skip-when-empty
noetl/ops#18     fix(agents): allow in-cluster execution past kube-context guard

noetl/gui#18     ci(release): raise build timeout to 60m + add GHA buildkit cache
```

13 PRs across three repos (`noetl/noetl`, `noetl/ops`, `noetl/gui`).

## What we discovered along the way (problems whose existence wasn't obvious)

1. **The catalog's `kind` column was lying about Mcp resources.** The CLI's
   catch-all `noetl catalog register` always sent `resource_type: "Playbook"`,
   and the server took that at face value, so `kind: Mcp` resources landed
   as `kind: playbook` and the dispatcher's `fetch_mcp_resource` rejected
   them. Fixed in #395 — the YAML's own kind: is authoritative.
2. **Two stale hand-maintained DSL schemas predated v10 entirely.** Both
   used the deprecated `next: -step:` list form and the old `call+args`
   step shape. Replaced with a single auto-generated `playbook.schema.json`
   sourced from the v10 Pydantic models, plus a regen script. (#396)
3. **Lifecycle agents' deprecated `next: -step:` list form passed catalog
   register but failed engine load** — the v10 `Step.next: NextRouter`
   rejected the list form, and `PlaybookRepo.load_playbook_by_id`
   swallowed the Pydantic ValidationError as None which the engine
   re-raised as the misleading "Playbook not found: catalog_id=...".
   Fixed at the YAML side (#16, six files) AND at the catalog register
   path (#397, server-side Pydantic validation that surfaces the field
   path at register time instead of at first execute).
4. **The 422 from the new register-time validation was being wrapped as
   500.** The bare `except Exception` in `/catalog/register` collapsed
   our intentional `HTTPException(422)` into a generic 500 with the
   422 detail stringified into the message. Fixed in #398.
5. **Deploy script hardcoded a `noetl-dev` podman machine** that not
   every dev environment has. Fixed in ops#17 — configurable per
   workload knob; setting it to `""` skips the check entirely.
6. **Lifecycle agents' kube-context guard tripped on in-cluster
   execution.** When the dispatcher hands off to a worker pod, there's
   no kubectl context (in-cluster auth via service account) and the
   guard's `kubectl config current-context != kind-noetl` check
   fails closed. Fixed in ops#18 — detect KUBERNETES_SERVICE_HOST and
   skip the guard when running in-cluster.
7. **Worker image shipped no helm or kubectl.** Lifecycle agents
   running `helm upgrade --install` and `kubectl get` got
   `helm: not found` / `kubectl: not found`. Fixed in #399 — Dockerfile
   patch baking in pinned versions of both, multi-arch.
8. **`kind: shell` was only available in the local rust binary.** The
   distributed worker (the one that picks up agent dispatches via NATS)
   raised `NotImplementedError("Tool kind 'shell' not implemented")`
   for every shell step. Fixed in #400 — full `noetl/tools/shell/`
   plugin with subprocess/jinja/timeout/aggregation, registered in the
   worker dispatch.
9. **Worker SA had no cluster-wide RBAC.** Even with helm+kubectl
   installed, helm-driven cluster installs failed with
   `namespaces "mcp" is forbidden`. Fixed in #401 — narrow
   `noetl-worker-lifecycle-installer` ClusterRole + ClusterRoleBinding
   covering the verbs lifecycle deploys actually need.
10. **GUI v1.3.0 / v1.3.1 release builds were cancelled at the 20m
    timeout.** PR #16's friendly run dialog pushed the bundle size
    enough that QEMU-emulated arm64 npm/Vite builds timed out. Fixed
    in gui#18 — raised cap to 60m + added GHA buildkit cache.

Not all of these were on the original architecture sketch — most
surfaced only through the deployment / verification chain. They're
the kind of bugs that only matter once the system is wired enough
to produce real cluster effects.

## Architecture state (Phases 1-4)

| Phase | What | Status |
|---|---|---|
| 1 | noetl Mcp resource lifecycle (#392/393) | merged, smoked, visible in GUI |
| 2 | noetl-side check_access enforcement (#394) | merged, deployed mode=skip |
| 3 | ops kubernetes MCP lifecycle agent fleet (ops#15-18) | merged, registered, dispatched |
| 4 | gui friendly playbook run dialog (gui#16/17/18) | merged, v1.3.1 image now buildable |
| supporting | catalog kind authority (#395), DSL schema regen (#396), register-time validation (#397), 500→422 status preservation (#398), worker image helm+kubectl (#399), kind:shell distributed (#400), worker cluster RBAC (#401), gui CI cache (gui#18) | all merged |

## Pending follow-ups

- **Investigate failed:True despite successful deploy** (#79). Helm
  install succeeded, pod is Running, but the agent's execution status
  reported failed. Likely a post-install assertion in the shell or
  python end-step parsing.
- **Bake mcp-server reader RBAC into the chart values** (#78). The
  `extraClusterRoles` values block in our `deploy.yaml` agent didn't
  translate into ClusterRole/ClusterRoleBinding objects during the
  helm install — manual `kubectl apply` patch required to give the
  kubernetes-mcp-server SA cluster-read RBAC. Either fix the chart
  values format or add an explicit `kubectl apply` step in the
  agent.
- **GUI: lifecycle card title vertical-character wrap** (#73).
  Cosmetic; cards on the right side of the catalog tile grid render
  the title one char per line. Likely word-break: break-all on a
  narrow flex column.
- **GUI prompt: context-aware lifecycle verbs** (#74). Typing `status`
  or `tools` after `cd /mcp/lifecycle:redeploy` resolves to the
  global noetl health-check, not the contextually-appropriate
  lifecycle verb. The buttons themselves work (mouse click into
  the run dialog).
- **Mcp tab + Add-MCP wizard** (#51). With everything else in place,
  this is now genuinely unblocked.
- **Improve `playbooks` terminal listing** (#37). Quality-of-life,
  pagination + filter.

## Submodule pointer state in ai-meta

- `repos/noetl` → `347ff5ec` (post-#400/#401)
- `repos/ops`   → `94d9ab9` (post-ops#17 — ops#18 already merged on
  same SHA via a follow-up bump earlier in the session)
- `repos/gui`   → tip-of-main with v1.3.1 published; v1.3.0 build
  was retriggered after gui#18 timeout fix and is still running.

## Files of note created/modified this session

- repos/noetl: `noetl/server/api/auth/{__init__,check_access}.py`,
  `noetl/server/api/catalog/{service,endpoint}.py`,
  `noetl/server/api/mcp/{endpoint,service}.py`,
  `noetl/core/dsl/{_generate_schema.py,playbook.schema.json}`,
  `noetl/tools/shell/{__init__,executor}.py`,
  `noetl/worker/nats_worker.py`,
  `docker/noetl/dev/Dockerfile`,
  `ci/manifests/noetl/rbac.yaml`,
  + tests under `tests/unit/server/api/{auth,catalog,mcp}/` and
    `tests/unit/tools/shell/`.
- repos/ops: 6 lifecycle agents + 1 Mcp template under
  `automation/agents/kubernetes/`; deploy script knobs in
  `automation/development/noetl.yaml`.
- repos/gui: `.github/workflows/build_on_release.yml`.

Tags: noetl, ops, gui, mcp, phase-1, phase-2, phase-3, phase-4,
      architecture, kind, end-to-end, milestone, dsl, rbac
