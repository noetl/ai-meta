# Travel agent vertex-ai Phase 3 closes GREEN — three-provider flagship complete

- date: 2026-05-10T16:00:00Z
- tags: travel-agent, vertex-ai, mcp-playbook, phase-3, green, gke, workload-identity, project-default-fix, retro

## What landed

- Ops PR (Phase 3 main): noetl/ops#59 (already merged)
- Ops PR (re-smoke fix): noetl/ops#60 — flip vertex_project default from
  `noetl-cluster` to `noetl-demo-19700101`
- Travel runtime registered on GKE: catalog id `623381857714832176`, version 2
- Vertex AI MCP playbook (unchanged) — single source of truth still holds
- Validation log appended: `bridge/outbox/codex-spike-green-validation.md`
- ai-meta close-out stack includes Phase 3 bridge results, ops/docs pointer
  bumps, validation-log evidence, and this memory entry.

## GREEN smoke evidence

| smoke                              | execution id           | effective_provider | fallback |
| ---------------------------------- | ---------------------- | ------------------ | -------- |
| `travel --provider vertex-ai help` | 623381985775321905     | vertex-ai          | none     |
| `travel --provider vertex-ai flights ...` | 623382273336804267 | vertex-ai      | none     |
| `travel --provider vertex-ai locations near Boston` | 623382578497585205 | vertex-ai | none |
| Direct `cd /mcp/vertex-ai; call chat_completion ping` | 623383029334933695 | n/a (returned "pong") | n/a |

All three travel smokes complete with `effective_provider='vertex-ai'`, no
provider_fallback_reason. Direct Vertex MCP returned "pong" from
gemini-2.5-flash. Workload Identity is the credential path
(`noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`).

## Retro: my AMBER diagnosis was on the wrong axis

I diagnosed AMBER as a Workload Identity / SA-JSON / GOOGLE_APPLICATION_CREDENTIALS
mismatch. Wrote three recipes (env-token, SA-JSON mount, WI). All wrong — auth
was already wired. The actual fix was a single-line project name flip in the
travel runtime workload defaults.

Why the misdiagnosis:
- I conflated "kind cluster" with "the cluster Codex was smoking against".
  Codex was actually port-forwarding to GKE (`localhost:18082`). The earlier
  rounds had been on kind, so I anchored on kind without checking.
- The error string `service-account credentials missing private_key or
  client_email` REALLY does come from the SA-JWT helper in vertex-ai.yaml.
  But that helper only runs when GOOGLE_APPLICATION_CREDENTIALS is set,
  which Workload Identity DOES NOT set. So in retrospect, that error
  shouldn't have been reached on a GKE pod at all — which means the error
  came from somewhere else (likely Codex's gcloud CLI context during the
  external MCP regression smoke, where it tried local SA-JWT against a
  malformed user ADC).
- I should have asked Codex which cluster the smokes ran against before
  designing the auth recipe round.

Lesson for next time: when a smoke fails with a credentials error, the FIRST
question is "what was the project / cluster / SA scope at the moment of
failure", not "which auth chain branch was hit". The chain branch tells you
what code path to read; the scope tells you whether the request was even
pointed at the right place.

## What was actually wrong

`workload.vertex_project` defaulted to `"noetl-cluster"` in the travel runtime
(via `{{ workload.gcp_project }}` which itself defaulted to `"noetl-cluster"`).
That's the original kind/local naming convention. The GKE project is
`noetl-demo-19700101`. So the Vertex AI request was a 4xx/auth-shaped error
from the wrong project, not a real auth failure. ops#60 flipped the default
to `noetl-demo-19700101`. After re-register (catalog v2), all three smokes
went GREEN.

This is a generalisable design rule worth pinning:

> When a runtime workload defaults to an environment-specific value (project
> ID, cluster name, region), make the default match the deployed environment
> — not the developer's local sandbox. Defaults are a tax that compounds
> across every caller who doesn't override.

It's the inverse of the "bare keychain references" rule from the flagship
arc: keychain Jinja resolves bare workload fields, but defaults-of-defaults
in workload Jinja chains are a hidden coupling. Worth a paragraph in
docs/reference/playbook_authoring_guide.md if a docs round comes around.

## Travel agent flagship retrospective — three phases

| phase | what landed                                              | architectural payoff                                |
| ----- | -------------------------------------------------------- | --------------------------------------------------- |
| 1     | Travel agent + Amadeus direct urllib + widget renderer   | Widgets-as-JSON, render-as-tail, prove ai_provider  |
| 2     | Amadeus calls route through `mcp/amadeus` MCP playbook   | "MCP is just a playbook" — first hop                |
| 3     | Vertex AI as third provider via `mcp/vertex-ai` MCP hop  | "MCP is just a playbook" — second hop, AI providers |

The travel runtime is now ~3 kinds of work composed:
- 1 urllib python step (OpenAI + Anthropic — kept direct because there's no
  MCP playbook for them yet; adding one would be a future architectural-purity
  round)
- 2 `tool: agent framework: noetl` MCP hops (Amadeus tooling + Vertex inference)
- N small render python steps producing widget trees as render-as-tail

This is the smallest possible glue around two MCP playbooks. The thesis from
round 9's playbook authoring guide ("playbooks are the unit of composition,
MCP is just a playbook with `exposes_as_mcp: true`") now has three concrete
load-bearing examples in production.

## Deferred follow-ups (still open)

- Audit table re-add as side effect inside each render_* python step (psycopg)
- Wire hotels and activities branches in the travel agent
- app:form widget for refining Amadeus filters before re-running
- Anthropic re-smoke once the Anthropic secret is provisioned in
  project 1014428265962 (still pending — Kadyapam owns)
- Ollama provider — needs in-cluster bridge URL routing design
- Investigate Amadeus test API 500s on flights/locations
- (NEW) Capture the workload-default-environment-mismatch lesson in the
  playbook authoring guide; pair with the bare-keychain-refs lesson

## Files

- `repos/ops/automation/agents/travel/runtime.yaml` (Phase 3 + ops#60 default fix)
- `repos/docs/docs/tutorials/07-travel-agent-with-widgets.md` (Phase 3 docs)
- `bridge/outbox/20260510-021500-travel-vertex-ai.result.json` (AMBER round 1)
- `bridge/outbox/20260510-040000-travel-vertex-ai-resmoke.result.json` (GREEN re-smoke)
- `bridge/outbox/codex-spike-green-validation.md` (GREEN paragraph appended)
- `bridge/inbox/delegated/20260510-021500-travel-vertex-ai.task.json` (Phase 3 main)
- `bridge/inbox/delegated/20260510-040000-travel-vertex-ai-resmoke.task.json` (re-smoke)
