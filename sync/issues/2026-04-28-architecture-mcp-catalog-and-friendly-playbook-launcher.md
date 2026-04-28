# Architecture — MCP catalog management + friendly playbook launcher in GUI

- Captured: 2026-04-28 (UTC)
- Reporter: Kadyapam (Cowork session)
- Status: open / design
- Severity: feature work, not a bug
- Repo(s) touched: `repos/noetl`, `repos/gateway`, `repos/gui`, `repos/docs`, `repos/e2e`
- Targets: `noetl/noetl` v2.25.x, `noetl/gui` v1.2.x

## Goal

Two related capabilities the user asked for in the same breath:

1. **Manage MCP servers as first-class catalog resources** that are
   provisioned, started, stopped, and observed via NoETL playbooks.
2. **Run any feature exposed via a NoETL playbook from the GUI in a
   user-friendly manner** — pick a playbook, get a generated form for
   its `workload`, run it, and watch results inline.

Today we already have the building blocks (PRs #386 / #387 / ops #11
landed `tool.kind: mcp`, `agent` catalog resources, the
`mcp_kubernetes_server` runtime agent, and the `kubernetes-mcp-server`
Helm deploy). What's missing is a coherent UX wrapper plus a couple of
catalog/runtime extensions to make those building blocks usable by
non-developers.

## Building blocks we already have

- **Catalog**: `Playbook`, `Agent`, `Tool`, `Model`, `Mcp`, `Memory`
  resource kinds, version-controlled, registered via
  `POST /api/catalog/register` and listed via
  `POST /api/catalog/list`.
- **Execution**: `POST /api/execute { path, version, workload }`
  returns an `execution_id`; `GET /api/executions/{id}` returns
  status; `GET /api/executions/{id}/events` returns the event log;
  `POST /api/executions/{id}/cancel` for graceful stop.
- **MCP runtime agents**: `repos/ops/automation/agents/kubernetes/runtime/mcp_kubernetes_server.yaml`
  registers as `resource_type=agent`. Calling that agent via
  `tool.kind: mcp` triggers a real MCP tool call against the
  in-cluster `kubernetes-mcp-server`.
- **GUI v1.1.3** (post-`#14` themes): catalog/execution pages,
  terminal-style prompt with `mcp` and `k8s` shortcuts already wired
  through agent playbooks.

## Gaps

### MCP catalog management

- A "Mcp" catalog entry today describes a *connection* (URL + tool
  list) but doesn't own its lifecycle. There's no `start`, `stop`,
  `status`, `restart`, or `uninstall` action callable from the GUI
  or from another playbook.
- There's no relationship binding between an `Mcp` resource and the
  `Agent` playbook that operates it. Right now `mcp status` works in
  the terminal because the terminal command happens to know the agent
  path.
- We can't yet register a *new* MCP server through a playbook in
  one shot: today the user has to (1) `kubectl apply` the deploy via
  `repos/ops`, (2) register a `Mcp` catalog entry, (3) register the
  matching `Agent` playbook, (4) wire it into the GUI's terminal
  command list.

### Friendly playbook launcher

- Catalog page lists playbooks but offers no form to fill in
  `workload` values. The user has to know the JSON shape and POST it
  through the API.
- There's no way to mark a playbook as "user-facing" vs.
  "infrastructure" — the catalog dump shows everything mixed.
- There's no per-playbook documentation surface. README content lives
  in the playbook YAML's `metadata.description`, but the GUI shows
  none of it on the run dialog.
- Execution detail page shows raw events, but doesn't surface the
  `output` value of the terminal step in a friendly way (what the
  user actually wants to see).

## Proposed design

### A. `Mcp` resource as a managed lifecycle object

Extend the `Mcp` catalog resource with explicit lifecycle metadata:

```yaml
apiVersion: noetl.io/v2
kind: Mcp
metadata:
  name: kubernetes
  path: mcp/kubernetes
  description: |
    In-cluster Kubernetes MCP server for read-only k8s observability.

spec:
  # Connection (already exists)
  url: http://kubernetes-mcp-server.mcp.svc.cluster.local:8080
  tools:
    - pods_list_in_namespace
    - namespaces_list
    # ...

  # NEW — lifecycle agent. Each verb resolves to an Agent playbook
  # path; the gateway calls /api/execute on the matching agent.
  lifecycle:
    deploy:    automation/agents/kubernetes/lifecycle/deploy
    redeploy:  automation/agents/kubernetes/lifecycle/redeploy
    undeploy:  automation/agents/kubernetes/lifecycle/undeploy
    status:    automation/agents/kubernetes/lifecycle/status
    restart:   automation/agents/kubernetes/lifecycle/restart

  # NEW — discovery. Where to introspect the running server's tool
  # list (instead of trusting the catalog blob).
  discovery:
    initialize_url: ${spec.url}/healthz
    tools_list_url: ${spec.url}/tools
    refresh_via:    automation/agents/kubernetes/lifecycle/discover

  # NEW — runtime context. Agent path the GUI/terminal should use to
  # actually call MCP tools. Same agent every existing terminal
  # command goes through, just made explicit on the resource.
  runtime:
    agent: automation/agents/kubernetes/runtime/mcp_kubernetes_server
```

Server-side changes (`repos/noetl`):

- New API: `POST /api/mcp/{path}/lifecycle/{verb}` — looks up the
  `Mcp` resource, reads `lifecycle.{verb}` agent path, and dispatches
  `/api/execute` with the resource as workload. Returns
  `execution_id`.
- New API: `POST /api/mcp/{path}/discover` — calls the
  `discovery.refresh_via` agent (or hits `tools_list_url` if no
  agent specified) and patches the catalog entry's `tools` array.
- Validation in `register_resource`: when `kind == Mcp`, require a
  `runtime.agent` so the GUI knows where to dispatch tool calls.

Gateway changes (`repos/gateway`):

- Forward the new `/api/mcp/{path}/...` endpoints to the noetl
  server. Add GraphQL field `Mcp.lifecycle` so the GUI can render
  lifecycle buttons.

### B. Friendly playbook launcher

GUI changes (`repos/gui`):

- **Tag user-facing playbooks** via a `metadata.exposed_in_ui: true`
  flag (or a list of paths in a settings file). The catalog page
  filters on this so end users only see actionable items.
- **Generate a workload form** from the playbook's
  `workload` object. For each top-level workload key, infer a UI
  control from the YAML default value's type:
    - string → text input
    - integer → number input with a step of 1
    - float → number input with arbitrary step
    - boolean → toggle
    - list → repeating row form
    - object → nested fieldset
    - special tags via comments (`# ui:enum=[a,b]`,
      `# ui:secret`, `# ui:credential=pg_*`) for richer controls.
- **Run dialog**: title = `metadata.name`, body = rendered
  markdown of `metadata.description`, form generated as above, two
  buttons — "Run" and "Run with overrides…" (the latter exposes the
  full workload as YAML).
- **Inline result panel**: when the user clicks Run, the GUI calls
  `/api/execute`, then opens an inline panel that subscribes to the
  execution's event stream and renders a small status pill plus the
  terminal step's `output` once the playbook completes. Link to the
  full execution detail page for power users.
- **Catalog page navigation**: add an "MCP" tab (sibling of
  Playbooks / Agents) that lists `Mcp` resources with lifecycle
  buttons (Deploy, Restart, Undeploy, Status). Each button kicks
  the matching lifecycle agent and opens the same inline result
  panel.

Server-side changes (`repos/noetl`):

- Add a `metadata.exposed_in_ui` and `metadata.ui_schema` field
  recognized by the catalog register endpoint. Make them optional;
  default `exposed_in_ui = false` so we don't surprise existing
  deployments.
- Add `GET /api/catalog/{path}/ui_schema` — returns the inferred
  workload schema (so the GUI can render forms without re-parsing
  YAML on the client).

Workload form inference details:

- Look at the YAML AST of the playbook's `workload` block. For each
  scalar value, take its type as the field type and the value as the
  default. For comments adjacent to a key, parse `# ui:` directives.
- Cache the inferred schema per `(catalog_id, version)`.

### C. Discovery flow

When a user wants to add a new MCP server in the GUI:

1. **Browse catalog** → click "Mcp" tab → "Add MCP server".
2. **Pick a template**: dropdown from a curated list maintained in
   `repos/ops/automation/agents/*/templates/`. Templates are
   themselves catalog `Mcp` resources with all the lifecycle wiring
   pre-populated.
3. **Fill workload form**: server name, namespace, image, port, etc.
   — generated from the template's `workload`.
4. **Submit**: GUI registers the resulting `Mcp` resource, then
   POSTs to `/api/mcp/{path}/lifecycle/deploy`. Inline result panel
   shows progress.
5. **Auto-discovery**: on `deploy` agent completion, the runtime
   triggers `/api/mcp/{path}/discover` to refresh the tool list.
6. **Now usable from the terminal**: GUI's terminal-prompt command
   list refreshes from `/api/catalog/list?resource_type=Mcp` so the
   new server's verbs (e.g. `myserver call <tool>`) work immediately.

## Implementation phases

**Phase 1 — server primitives** (`repos/noetl`):

- Add `Mcp` lifecycle + discovery fields to the resource model.
- Add `/api/mcp/{path}/lifecycle/{verb}` and
  `/api/mcp/{path}/discover` endpoints.
- Add `/api/catalog/{path}/ui_schema` endpoint.
- Tests under `tests/integration/api/mcp/`.

**Phase 2 — gateway shim** (`repos/gateway`):

- Forward the new endpoints. Update GraphQL `Mcp` type.
- Tests under `tests/integration/gateway/mcp/`.

**Phase 3 — ops templates** (`repos/ops`):

- Refactor `automation/agents/kubernetes/runtime/mcp_kubernetes_server.yaml`
  to be the *runtime* agent only.
- Add `automation/agents/kubernetes/lifecycle/{deploy,redeploy,undeploy,status,restart,discover}.yaml`.
- Refactor `automation/development/mcp_kubernetes.yaml` to register
  the `Mcp` catalog resource (with full lifecycle wiring) instead of
  just deploying the pod.

**Phase 4 — GUI** (`repos/gui`):

- New "Mcp" tab on the catalog page with lifecycle buttons.
- Run dialog with form generator + inline result panel.
- "Add MCP server" wizard.
- Updated terminal-prompt to refresh commands from catalog.

**Phase 5 — docs + e2e** (`repos/docs`, `repos/e2e`):

- Add user docs under `docs/features/managing_mcp_servers.md` and
  `docs/features/running_playbooks_from_ui.md`.
- Add e2e fixture: `fixtures/playbooks/ui_run_test/` that tests the
  workload-form inference + inline result panel against a tiny
  hello-world playbook.

## Risks / open questions

- **Versioning**: when a `Mcp` resource version is bumped, how does
  the GUI's terminal-prompt cache invalidate? Suggest the GUI poll
  `/api/catalog/list?resource_type=Mcp` every N seconds or on
  catalog page navigation.
- **Auth**: `mcp lifecycle/deploy` could nuke a production MCP. Lock
  the lifecycle endpoints behind the `admin` role + an explicit
  confirmation step in the GUI.
- **Form inference fidelity**: YAML doesn't carry rich type info for
  optional fields. The `# ui:` comment scheme needs guardrails
  (parser must tolerate misformatted comments without crashing
  registration).
- **Cross-cluster MCP servers**: today everything assumes the MCP
  lives in the same cluster as the noetl server. The lifecycle agent
  approach generalizes (different agent → different cluster), but
  needs explicit `cluster_context` field on the `Mcp` resource.

## Action items

- [ ] Open `noetl/noetl` issue with this design and Phase 1 scope.
- [ ] Open `noetl/gui` issue mirroring Phase 4 with mockups.
- [ ] Open `noetl/ops` issue for the lifecycle agent template
  refactor (Phase 3).
- [ ] Track in ai-meta `memory/current.md` Open Items.
