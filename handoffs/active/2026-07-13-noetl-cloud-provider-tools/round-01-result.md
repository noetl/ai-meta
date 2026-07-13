---
thread: 2026-07-13-noetl-cloud-provider-tools
round: 1
from: claude
to: codex
created: 2026-07-13T15:35:55Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase A — NoETL Cloud Provider Tool: inspection + design

Phase A (inspect + design) is complete. Phase B (implement MVP) was **NOT**
started — the wait phrase `implement provider tool` has not been given. No
remote writes, no cloud/GCP mutations, no `gcloud`/API calls, no builds, no
deploys were performed. Only read-only inspection plus this result file were
done.

`status: partial` reflects the phase gate: Phase A designed, Phases B and C
deliberately not run (gated). The design below is the deliverable and is
implementation-ready.

## Phase A — inspect and design

### 0. Checkout + preconditions verified

- Operating in `/Volumes/X10/projects/noetl/ai-meta` (== `/Users/akuksin/projects/noetl/ai-meta`;
  same inode — `/Users/akuksin/projects` resolves onto the `/Volumes/X10` mount).
- Handoff prompt, `handoffs/README.md`, `AGENTS.md`, and
  `agents/rules/execution-model.md` all read end-to-end and exist.
- Correct checkout confirmed; did not improvise.

### 1. Where the tool interface actually lives (the load-bearing finding)

The prompt guesses `repos/noetl` (Python). The current tool execution path is
**Rust**, not Python. Tool kinds are implemented in the `noetl-tools` crate
(`repos/tools`) and dispatched by the Rust worker (`repos/worker`). Per
`agents/rules/handoff-routing.md`, **Claude writes this Rust directly — no Codex
Rust handoff.** So the implementation target for Phase B is:

- **`repos/tools`** — add the new tool kind (primary change).
- **`repos/worker`** — no code change needed for dispatch (see §3); a metrics
  label and an image rebuild for kind validation are the only worker touches.

The Python `repos/noetl` server is not on the tool-dispatch hot path for the
Rust runtime that is in prod today (`app=noetl-server-rust`, Python scaled to 0).
A Python provider tool would be dead code for the shipped runtime. **Recommend
Rust-only.**

### 2. Current tool-kind architecture (`repos/tools`)

- **`registry.rs`** — the `Tool` trait + `ToolRegistry`.
  - `trait Tool { fn name(&self) -> &'static str; fn side_effecting(&self) -> bool; async fn execute(&self, &ToolConfig, &ExecutionContext) -> Result<ToolResult, ToolError>; }`
  - `ToolConfig { kind: String, #[serde(flatten)] config: serde_json::Value, timeout, retry, auth: Option<AuthConfig> }`.
    The `#[serde(flatten)] config` means **any extra YAML keys on the tool block
    (`provider`, `runtime`, `action`, `dry_run`, `input`) land in `config`
    automatically** — no parser change is needed to carry the new fields.
  - `AuthConfig` already models GCP: `auth_type: AuthType` (has `GcpAdc`
    variant), `scopes: Option<Vec<String>>`, plus `credential`/`token`.
  - `kind_is_side_effecting(kind)` (noetl/ai-meta#104 Phase E) — conservative
    default `true` for every kind except `noop`/`rhai`. `provider` mutating
    actions are side-effecting; a plan/dry-run is not. The static per-kind flag
    is `true` (safe over-classification) — the adopt-only resume barrier makes
    this correct; a per-invocation `dry_run ⇒ false` refinement is a future
    optimization, not a correctness need. Recommend leaving `provider` at the
    static default `true`.
- **`tools/mod.rs`** — `create_default_registry()` registers all 19 built-in
  tools. **Adding a kind = one `mod`, one `pub use`, one `registry.register(...)`
  line here.**
- **`auth/gcp.rs`** — `GcpAuth` already wraps the `gcp_auth` crate's ADC
  provider chain (GOOGLE_APPLICATION_CREDENTIALS → gcloud config → GCE/GKE
  metadata). `get_token(scopes)` returns a bearer access token. Default scope
  `https://www.googleapis.com/auth/cloud-platform`. **The auth boundary the
  prompt asks for already exists and is reused, not rebuilt.**
- **`auth/resolver.rs`** — `AuthResolver::get_gcp_token(scopes)` is the public
  entry the provider tool calls. `resolve_gcp_adc` already defaults the
  cloud-platform scope. This keeps credentials outside Git (ADC), never in
  YAML.
- **`result.rs`** — `ToolResult { status, data: Option<Value>, error, ... }`.
  Normalized JSON result goes in `data`. `ToolResult::success(json)` /
  `ToolResult::error(msg)`.
- **`error.rs`** — `ToolError` variants: `NotFound, ExecutionFailed, Timeout,
  Configuration, Template, Http, Database, Auth, Process, Json, Io, Script`.
  Unknown provider/action → `ToolError::Configuration(...)`; auth failure →
  `ToolError::Auth(...)`; API/transport failure → `ToolError::Http(...)`.
- **`context.rs`** — `ExecutionContext { execution_id, step, variables,
  secrets, server_url, worker_id, command_id, call_index }`. Provider tool
  needs `execution_id` (observability label) and, for auth-alias resolution,
  `secrets`.
- **Dependencies already present**: `gcp_auth`, `reqwest`, `serde`,
  `serde_json`, `tokio`, `async-trait`. The official Google Cloud **Rust SDK
  (`google-cloud-rust`) is NOT a dependency** — see §4.

### 3. Worker dispatch path (`repos/worker/src/executor/command.rs`) — no change needed

`command.tool_kind` → reconstructs a `ToolConfig` (injecting `kind` from
`tool_kind`, flattening `input.tool_config`) → `tool_registry.execute(kind,
config, ctx)`. A `provider` kind registered in `create_default_registry()`
flows through this path transparently. Per-kind metrics
(`noetl_worker_dispatch_duration_seconds{tool_kind}`,
`..._errors_total{tool_kind}`) are emitted generically by `record_dispatch` —
`provider` gets instrumented for free, satisfying `agents/rules/observability.md`
Principle 1 (span + metric + `execution_id` all already present on the dispatch
boundary).

### 4. Google SDK vs REST — the MVP decision

Three build options were on the table (prompt §Phase A.3):

| Option | Verdict |
| --- | --- |
| (a) **Direct Rust impl in NoETL via REST + `gcp_auth`** | **CHOSEN for MVP.** |
| (b) Provider adapter *binary* invoked by NoETL | Rejected — reintroduces the `gcloud`-style subprocess coupling the whole initiative is removing; breaks the atomic-worker model. |
| (c) Intermediate JSON contract + executor stub | Partially adopted — the typed operation spec IS the contract; the tool is the executor. Not a separate stub process. |

**Why REST, not the official `google-cloud-rust` SDK, for the MVP:**

- The SDK is a large, multi-crate dependency graph (one crate per service:
  `google-cloud-resourcemanager`, `-billing`, `-serviceusage`, …), pulling
  `tonic`/`prost`/gRPC and requiring Rust ≥1.88. Adding that to `noetl-tools`
  materially grows worker build time — the crate is already fighting build
  weight (DuckDB C++ gated behind a feature per noetl/ai-meta#185; #187 dropping
  DuckDB entirely). Adding a 150-service gRPC SDK cuts against that.
- All 11 target operations are plain REST-JSON: Cloud Resource Manager v3,
  Cloud Billing v1, Service Usage v1. `reqwest` + a `gcp_auth` bearer token
  covers every one with a few hundred lines and **zero new heavy deps**.
- The abstraction is designed so a `runtime: rust-sdk` backend can be added
  later behind the same tool interface without a YAML change (see §5) — the
  MVP ships `runtime: rest` (or unset → default). The prompt's example uses
  `runtime: rust-sdk`; the tool accepts both and maps `rust-sdk` → the REST
  backend for now, emitting a one-line note in `result.data.backend` so the
  playbook can see which path ran. When the SDK backend lands it's a drop-in.

Reference (verified in the target contract doc, not re-fetched live): Google
Rust SDK GA 2025-09-09, `googleapis/google-cloud-rust`, Rust ≥1.88, covers
Storage/Vertex/Secret Manager/150+ services.

### 5. Proposed tool interface (cross-cloud, Google-first)

YAML surface the playbook writes (matches the prompt + the runtime doc, with
`runtime` optional):

```yaml
tool:
  kind: provider
  provider: google              # provider family — google | aws | azure (later)
  runtime: rest                 # rest (default/MVP) | rust-sdk (future, same iface)
  action: google.cloudresourcemanager.projects.ensure
  dry_run: "{{ workload.action != 'apply' }}"   # true => plan only, no mutation
  input:
    project_id: shastaratech-youtube-prod
    parent: folders/by-display-name/20-media
  auth:                         # optional; defaults to GCP ADC for provider=google
    type: gcp_adc
    scopes: ["https://www.googleapis.com/auth/cloud-platform"]
```

Internal shape (Rust):

- `ProviderTool` implements `Tool`, `name() == "provider"`.
- Parse `config` → `ProviderSpec { provider: ProviderFamily, runtime: Backend,
  action: String, dry_run: bool, input: serde_json::Value }`.
- `ProviderFamily` enum: `Google` (only implemented arm); `Aws`/`Azure` parse
  but return `ToolError::Configuration("provider 'aws' not yet implemented")` —
  the cross-cloud seam is explicit, not baked out.
- Dispatch on `action`: `provider.service.resource.verb` string. A
  `GoogleProvider` struct owns an ` action -> handler` match. Each handler:
  1. builds the REST request (method, URL, body) from `input`,
  2. for `ensure`/`enable` verbs, does a **GET-first idempotency check**
     (describe/list) and short-circuits to `{"changed": false, "existing":
     {...}}` if already present,
  3. if `dry_run` → returns the planned request as normalized JSON
     (`{"dry_run": true, "would_call": {method, url, body_shape}}`) **without**
     minting a token or calling Google,
  4. else mints an ADC bearer token via `AuthResolver::get_gcp_token(scopes)`,
     issues the call, normalizes the response.
- **Normalized result** (`ToolResult.data`):
  ```json
  {
    "provider": "google",
    "action": "google.cloudresourcemanager.projects.ensure",
    "dry_run": false,
    "changed": true,
    "resource": { "...normalized google response..." },
    "backend": "rest"
  }
  ```

### 6. Initial Google operation scope → REST mapping (design, not yet coded)

| Action (`action:` value) | HTTP | Endpoint | Idempotency |
| --- | --- | --- | --- |
| `google.cloudresourcemanager.folders.list` | GET | `cloudresourcemanager.googleapis.com/v3/folders?parent=organizations/{org}` | read-only |
| `google.cloudresourcemanager.folders.ensure` | POST (`v3/folders`) | list under parent → create if display_name absent | GET-first |
| `google.cloudresourcemanager.organizations.iam.get_policy` | POST | `v3/organizations/{org}:getIamPolicy` | read-only |
| `google.cloudresourcemanager.organizations.iam.ensure_binding` | POST `:setIamPolicy` | getIamPolicy → add member/role if absent → setIamPolicy w/ etag | read-modify-write w/ etag |
| `google.cloudresourcemanager.projects.describe` | GET | `v3/projects/{project_id}` | read-only |
| `google.cloudresourcemanager.projects.ensure` | POST (`v3/projects`) | get → create if 404, set `parent` | GET-first |
| `google.cloudbilling.projects.link` | PUT | `cloudbilling.googleapis.com/v1/projects/{project_id}/billingInfo` | idempotent PUT (compare current billingAccountName) |
| `google.cloudbilling.billing_accounts.iam.get_policy` | POST | `v1/billingAccounts/{id}:getIamPolicy` | read-only |
| `google.cloudbilling.billing_accounts.iam.ensure_binding` | POST `:setIamPolicy` | get → merge → set w/ etag | read-modify-write w/ etag |
| `google.serviceusage.services.list_enabled` | GET | `serviceusage.googleapis.com/v1/projects/{project_id}/services?filter=state:ENABLED` | read-only |
| `google.serviceusage.services.enable` | POST | `v1/projects/{project_id}/services/{service}:enable` | inherently idempotent (returns done if already enabled) |

Note the playbook-emitted action names (`folders.ensure`, `projects.ensure`,
`services.enable`, `billingAccounts.iam.ensure_binding`, etc. — see
`gcp-org-playbooks/automation/gcp_org/*.yaml`) map 1:1 onto the fully-qualified
`google.<service>.<resource>.<verb>` action strings above. The provider tool
accepts both the short form (as emitted today) and the qualified form; recommend
normalizing to the qualified form internally.

Long-running-op note: `projects.create`/`folders.create` return an Operation
that must be polled. MVP polls inline with a bounded timeout (folder/project
creation completes in seconds) — acceptable under the execution-model
"few seconds" slot rule. If any op exceeds that, the callback/hook pattern is
the correct escalation (documented as a follow-up, not built in MVP).

### 7. Execution-model / rules conformance check

- **Gateway = gatekeeper**: provider tool runs inside a **worker/playbook step**,
  never the gateway. ✅ Data touch is in the playbook step.
- **Worker = atomic compute**: one action per dispatch, stateless, releases the
  slot. ✅ (long ops bounded; callback pattern noted for the overflow case.)
- **These are EXTERNAL subsystems** (Google APIs), so
  `agents/rules/data-access-boundary.md` puts them squarely in the
  "playbook acts as client to external system" lane — direct API call is the
  right shape, exactly like the auth/Duffel/Amadeus tools. Not NoETL-owned
  data. ✅
- **Secrets/credentials** (`execution-model.md`): ADC / keychain-referenced;
  **no billing IDs, OAuth files, SA keys, or tokens in YAML or Git**. The
  billing account ID stays a runtime `--set` input, never committed (the
  gcp-org-playbooks already enforce this). ✅
- **No credential logging** (`agents/rules/logging.md`): the tool must never log
  the bearer token, request Authorization header, or the setIamPolicy body
  members-as-secrets. Design mandates a `redact` step on any emitted request
  echo (the `would_call` dry-run echo carries method+url+**body shape**, not the
  token). The tools crate has no shared scrubber today (grep found none) — the
  provider tool owns its own field allowlist for the echoed request. ✅ (called
  out as a Phase B test.)
- **`agents/rules/no-default-connection.md`**: `provider=google` defaults to ADC
  which is a *platform* trust (GKE workload identity / gcloud), not a
  business-logic DB connection, so the "explicit auth alias" rule's DB-connection
  intent is satisfied by the ADC boundary; a step MAY still pin `auth:` scopes.
  No ambient DB fallback is introduced. ✅
- **Observability** (`agents/rules/observability.md`): dispatch span + per-kind
  metrics already fire for any registered kind; `execution_id` is on the span.
  Recommend one added counter `noetl_provider_action_total{provider,action,dry_run,outcome}`
  in Phase B. ✅ (design)

### 8. Design-doc location (Phase A step 4)

The prompt's Phase A step 4 asks to "write or update a design doc in the
relevant NoETL docs location." The **session constraint for this run restricts
me to read-only inspection + writing this result file** — so I did NOT write
into `repos/tools` or `repos/noetl` (that would be a submodule/product write,
and those trees carry unrelated dirty state I must not disturb). The full design
is embedded in this result instead. **Phase B should land the design doc as:**

- `repos/noetl-tools-wiki/Provider-Tool.md` (the tools crate's wiki — sibling of
  the existing `mcp-tool.md`, `nats-tool.md`, `Snowflake-Tool.md`), cross-linked
  from `Home.md` + `_Sidebar.md`, per `agents/rules/wiki-maintenance.md` Rule 1;
- plus module-level `//!` docs in `repos/tools/src/tools/provider.rs`.

## Phase B — implement MVP locally

**NOT STARTED — gated on wait phrase `implement provider tool`.** No code
written, no tests added, no builds run, no worker rebuild, no kind validation.

When authorized, the smallest useful path (recommended order):

1. `repos/tools/src/tools/provider.rs` — `ProviderTool` + `ProviderSpec`
   parsing + `ProviderFamily`/`Backend` enums + `GoogleProvider` with a handler
   match. Start with the 3 read-only actions (`folders.list`,
   `projects.describe`, `services.list_enabled`) + 1 mutating with GET-first
   idempotency (`services.enable`), the rest stubbed to
   `ToolError::Configuration("<action> not yet implemented")`.
2. `repos/tools/src/tools/mod.rs` — `mod provider; pub use ...; registry.register(ProviderTool::new());`.
3. Tests (prompt Phase B.6): spec parsing; `dry_run=true` returns `would_call`
   and mints no token / makes no network call (assert via a no-network unit
   test); unknown provider + unknown action → `Configuration` error; **secret
   redaction** — assert the emitted result/echo never contains a token or the
   Authorization header.
4. Sample playbook under `repos/tools/examples/` or an e2e fixture mirroring
   `gcp-org-playbooks` `folders.list` / `services.enable` specs, `dry_run` only.
5. No real cloud mutation in tests — all network-touching paths behind
   `dry_run` or a mocked transport.
6. Kind validation (`agents/rules/deployment-validation.md`): rebuild worker
   image, load into `kind-noetl`, run the sample playbook in `plan` mode only.

## Phase C — report and integration instructions

**NOT STARTED — depends on Phase B.** No files changed, no commands run beyond
read-only inspection, no branch/SHA to report, no PR. When Phase B lands, Phase C
reports exact files changed, `cargo test`/`clippy` results, which actions ship
vs remain stubbed, and the `repos/tools` branch + commit SHA (no push / no PR
unless explicitly instructed).

## Issues observed

- **Prompt's implementation-target guess (`repos/noetl`, Python) is off.** The
  live tool path is Rust (`repos/tools` + `repos/worker`); Python is scaled to 0
  in prod. Building this in Python would be dead code. Design retargets to Rust.
- **No shared secret-scrubber in the `noetl-tools` crate.** Redaction today is
  server-side (`scrub::scrub_in_place`) and per-tool. The provider tool must own
  its own request-echo field allowlist. Flagged as a Phase B test requirement.
- **`dry_run` has no precedent in the tools crate** (grep found none). This is a
  new tool-level concept the provider kind introduces; worth a short note on the
  tools wiki so other kinds can adopt the same convention later.
- **Long-running Operations** (project/folder create) need inline polling with a
  bounded timeout in MVP; over-budget ops should move to the callback/hook
  pattern (execution-model). Design notes it; MVP assumes seconds-scale completion.

## Manual escalation needed

- **Human go-ahead to start Phase B** — reply with the wait phrase
  `implement provider tool`. Nothing further proceeds without it.
- **Decision (reversible, defaulted; documented as open question):** MVP ships
  `runtime: rest` and maps `rust-sdk` → REST with a `backend` note, rather than
  adding the heavy `google-cloud-rust` SDK dependency now. If you want the real
  SDK backend in the first round instead, say so — it changes the dependency
  footprint and worker build time materially.
- **No credentials were requested or used.** ADC resolution is a Phase B runtime
  concern; nothing to escalate for Phase A.

---
**Confirmation:** Phase B was NOT started. No remote writes, no cloud/GCP
mutations, no state-changing gcloud/API calls, no deploys, no worker rebuild
occurred. Read-only inspection + this result file only.
