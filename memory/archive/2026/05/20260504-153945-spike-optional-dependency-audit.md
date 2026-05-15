# 2026-05-04 — Spike additions audited for optional-dependency contract

User flagged a critical architectural concern after the spike landed:
"all new features are optional and does not block core deployment
and functionality of noetl. noetl supose to work with and without ai
functionality. it's up to playbook to report if runtime dependency
is missing but it should not crash noetl server or worker."

Audited every entry point added by the spike (Gaps 1/2/3/4/4.1/5)
for graceful degradation. Most paths were already defensive by
design (lazy imports, try/except, sibling-module deps). Two
hardening fixes:

1. **`_invoke_noetl_playbook` (Gap 1)** — wrapped the lazy
   `execute_playbook_task` import in try/except so ImportError
   surfaces as a clean envelope:
   ```
   error.kind = "agent.dependency"
   error.code = "WORKFLOW_PLUGIN_UNAVAILABLE"
   ```
   Previously: outer `execute_agent_task` caught the exception but
   the message ("an exception happened during agent execution")
   didn't tell the operator *why*. Now the dependency-missing case
   is a typed failure mode.

2. **`noetl/tools/ollama_bridge/__init__.py` (Gap 5)** — switched
   from eager `from .server import build_app` to lazy
   `__getattr__`. Importing the package now does zero work; the
   server module loads on first attribute access. Belt + suspenders
   for any future code path that introspects the package without
   actually wanting to start the bridge.

Two new smoke tests lock in the contract:

- `scripts/optional_ai_smoke.py` — 6/6 pass. Verifies
  framework=noetl returns clean envelope on missing workflow
  plugin; AST-checks that `execute_playbook_task` refs are
  confined to the framework=noetl helpers; verifies importing
  ollama_bridge doesn't leak aiohttp/fastapi/uvicorn into
  sys.modules; covers the lazy-attribute path.
- Existing `scripts/auto_troubleshoot_smoke.py` re-run — 9/9
  still pass.

Docs entry: `repos/docs/docs/architecture/agent_orchestration.md`
gained a new "Optional-dependency contract" section explaining
the no-crash guarantee + the structured error envelope shape.

PR pending: `kadyapam/spike-optional-degradation` against
`noetl/noetl`.

## Contract summary post-merge

| Missing component                              | Worker / server behaviour          |
|-----------------------------------------------|-----------------------------------|
| aiohttp / fastapi / uvicorn                    | core boots; Ollama bridge can't run |
| `noetl.core.workflow.playbook`                 | core boots; framework=noetl returns typed error per call; other frameworks unaffected |
| Troubleshoot agent not registered              | core boots; auto-dispatch silently no-ops; manual call returns 404 |
| Ollama not running                             | core boots; mcp/ollama calls return JSON-RPC -32030 |

AI features are opt-in at deployment time (packages installed,
catalog entries registered, sidecars deployed). Core stays running
through every kind of AI-subsystem absence.

Tags: spike, optional-deps, mcp, ollama, ai-os, hardening, audit
