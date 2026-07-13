---
thread: 2026-07-13-noetl-cloud-provider-tools
round: 1
from: claude
to: codex
created: 2026-07-13T15:39:58Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase A — NoETL Cloud Provider Tool: inspection + design

This is the **authoritative** Phase A result (two duplicate sessions were
started from timed-out retries and aborted; this canonical session
re-verified every finding against the code before writing).

Phase A (inspect + design) is complete. Phase B (implement MVP) and Phase C
(report) were **NOT** started — the wait phrase `implement provider tool`
has not been given. No remote writes, no cloud/GCP mutations, no
`gcloud`/API calls, no builds, no worker rebuild, no deploys, no kind/prod
actions. Only read-only inspection of the repos plus this result file.

`status: partial` maps to the README definition precisely — "some phases
ran, some were gated and skipped; report says exactly which." Phase A ran
and is reported in full below; Phases B and C are gated and deliberately
deferred.

## Phase A — inspect and design

### 0. Preconditions verified

- Operating in `/Volumes/X10/projects/noetl/ai-meta` (== the handoff's
  `/Users/akuksin/projects/noetl/ai-meta`; same tree via the `/Volumes/X10`
  mount).
- Read end-to-end and confirmed present: the round-01 prompt,
  `handoffs/README.md`, `AGENTS.md`, `agents/rules/execution-model.md`, plus
  the load-bearing corollary rules (`data-access-boundary.md`,
  `no-default-connection.md`, `observability.md`, `handoff-routing.md`,
  `safety.md`), and the target contract
  `gcp-org-playbooks/docs/noetl-google-api-runtime.md`.
- Read the GCP org playbooks that emit the operation specs the tool consumes:
  `automation/gcp_org/{org_folders,org_iam,billing_iam,project_factory,youtube_publisher_project}.yaml`.

### 1. Where the tool interface actually lives (load-bearing finding)

The prompt guesses `repos/noetl` (Python). **The live tool-execution path is
Rust, not Python.** Tool kinds are implemented in the `noetl-tools` crate
(`repos/tools`) and dispatched by the Rust worker (`repos/worker`). Prod runs
`app=noetl-server-rust` with the Python stack scaled to 0, so a Python
provider tool would be dead code on the shipped runtime. Per
`agents/rules/handoff-routing.md`, **Claude writes this Rust directly — no
Codex Rust handoff.**

Phase B implementation target:

- **`repos/tools`** — add the new `provider` tool kind (the only substantive
  code change).
- **`repos/worker`** — no dispatch code change needed (see §3); only an image
  rebuild for kind validation and, optionally, one added counter.

### 2. Current tool-kind architecture (`repos/tools`, verified line-by-line)

- **`registry.rs:174` — the `Tool` trait.**
  `fn name(&self) -> &'static str`, `fn side_effecting(&self) -> bool`
  (default delegates to `kind_is_side_effecting(name)`), and
  `async fn execute(&self, &ToolConfig, &ExecutionContext) -> Result<ToolResult, ToolError>`.
- **`registry.rs:13` — `ToolConfig`.**
  `{ kind: String, #[serde(flatten)] config: serde_json::Value, timeout, retry, auth: Option<AuthConfig> }`.
  The `#[serde(flatten)] config` means the extra YAML keys on the tool block
  (`provider`, `runtime`, `action`, `dry_run`, `input`) land in `config`
  automatically — **no framework parser change is needed** to carry the new
  fields; the `ProviderTool` deserializes its own typed spec out of `config`.
- **`registry.rs:169` — `kind_is_side_effecting`** (noetl/ai-meta#104 Phase E).
  Conservative default `true` for every kind except `noop`/`rhai`. A
  mutating `provider` action is side-effecting; a plan/dry-run is not, but the
  static per-kind default `true` is a safe over-classification (the adopt-only
  resume barrier makes it correct). **Recommend leaving `provider` at the
  static default `true`.**
- **`tools/mod.rs:80` — `create_default_registry()`** registers all 19 built-in
  kinds. Adding a kind = one `mod`, one `pub use`, one `registry.register(ProviderTool::new())`.
- **`auth/gcp.rs` — `GcpAuth`** already wraps the `gcp_auth` crate's ADC
  provider chain (`GOOGLE_APPLICATION_CREDENTIALS` → gcloud config → GCE/GKE
  metadata). `get_token(scopes)` returns a bearer token; `DEFAULT_SCOPES =
  ["https://www.googleapis.com/auth/cloud-platform"]`. **The auth boundary the
  prompt asks for already exists and is reused, not rebuilt.** The `http` tool
  already exposes `auth.type: gcp_adc`, so the pattern is precedented.
- **`result.rs` — `ToolResult`** `{ status, data: Option<Value>, error, ... }`,
  `success(json)` / `error(msg)`. Normalized JSON goes in `data`.
- **`registry.rs:82` — `AuthConfig`** already models GCP: `auth_type: AuthType`
  (has a `GcpAdc` variant), `scopes: Option<Vec<String>>`, plus
  `credential`/`token`. The provider tool's optional `auth:` block reuses this.
- **Dependencies already present** (no heavy new deps for the MVP): `gcp_auth`,
  `reqwest`, `serde`, `serde_json`, `tokio`, `async-trait`. The official
  `google-cloud-rust` SDK is **not** a dependency — see §4.

### 3. Worker dispatch path — no change needed

`repos/worker/src/executor/command.rs:259` builds the registry once via
`create_default_registry()`; the dispatch (`command.rs:~736`) special-cases
only `tool_kind == "wasm"`, otherwise routes to `registry.execute(kind, config, ctx)`.
The step's `tool:` block is reconstructed into `tool_config` with `kind`
injected from `command.tool_kind` and `input.tool_config` flattened
(`command.rs:535-575`). **A `provider` kind registered in the default registry
flows through this path transparently — zero worker code change.** Per-kind
dispatch metrics (`noetl_worker_dispatch_duration_seconds{tool_kind}`,
`..._errors_total{tool_kind}`) fire generically, so `provider` is instrumented
for free (satisfies `observability.md` Principle 1: span + metric +
`execution_id` on the dispatch boundary).

### 4. Google SDK vs REST — the MVP decision

Three build options were on the table (prompt Phase A.3):

| Option | Verdict |
| --- | --- |
| **(a) Direct Rust `provider` tool in `noetl-tools`, REST + `gcp_auth`** | **CHOSEN for MVP.** |
| (b) Provider adapter *binary* invoked by NoETL | Rejected — reintroduces the `gcloud`-style subprocess coupling the whole initiative is removing; adds a second process + auth surface; breaks the atomic-worker model. |
| (c) Intermediate JSON contract + executor stub | Partially adopted — the typed operation spec IS the contract; the tool is the executor. Not a separate stub process that can't `apply`. |

**Why REST-first, not the official `google-cloud-rust` SDK, for the MVP:**

- The SDK is a large multi-crate graph (one crate per service:
  `google-cloud-resourcemanager`, `-billing`, `-serviceusage`, …), pulls
  gRPC/`tonic`/`prost`, and requires Rust ≥1.88. `noetl-tools` is already
  managing build weight (DuckDB C++ gated behind a feature per
  noetl/ai-meta#185; #187 dropping DuckDB). Adding a 150-service gRPC SDK cuts
  against that.
- All 11 target operations are plain REST-JSON against Cloud Resource Manager
  v3, Cloud Billing v1, and Service Usage v1. `reqwest` + a `gcp_auth` bearer
  token covers every one in a few hundred lines with **zero new heavy deps**.
- The interface is designed (see §5) so a `runtime: rust-sdk` backend can be
  added later behind the same YAML with no playbook change. MVP ships
  `runtime: rest`; the prompt's example uses `rust-sdk`, so the tool accepts
  both and maps `rust-sdk` → the REST backend for now, echoing which path ran
  in `result.data.backend`. When the SDK backend lands it's a drop-in.

Reference (from the target contract doc, not re-fetched live): Google Cloud
Rust SDK GA 2025-09-09, `googleapis/google-cloud-rust`, Rust ≥1.88, covers
Storage / Vertex AI / Secret Manager / 150+ services.

### 5. Proposed tool interface (cross-cloud, Google-first)

YAML surface the playbook writes (matches the prompt + the runtime doc;
`runtime` optional, `auth` optional):

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
- **Auth model (RESOLVED — user decision, round-01 review): explicit `auth:`
  required for mutations.** Any mutating action (apply mode, i.e. `dry_run`
  false) MUST carry an explicit `auth:` alias naming a credential that is
  resolved through the keychain/credential path — **no ambient ADC fallback**.
  If a mutation is dispatched with `auth:` omitted (or empty), the tool returns
  a clear `ToolError::Configuration` naming the missing `auth:` field and makes
  **no** network call — it never silently falls back to ADC. Plan/dry-run mode
  stays credential-free: it mints no token and needs no `auth:`, consistent
  with the dry-run design below. (This is the recommended option from the
  original open question #3; the user confirmed it during round-01 review.)
- Parse `config` → `ProviderSpec { provider: ProviderFamily, runtime: Backend,
  action: String, dry_run: bool, input: serde_json::Value }`.
  - `dry_run` deserializes flexibly: bool **or** the strings
    `"true"`/`"false"`/`""` (templates render to strings). **Default `true`**
    (plan) — the tool never silently applies.
  - `action` accepts the fully-qualified
    `google.<service>.<resource>.<verb>` form **and** the short
    `<resource>.<verb>` form the playbooks emit today (with the sibling
    `service`/`api_version` keys); both normalize to the qualified key via a
    small service-domain table (`cloudresourcemanager.googleapis.com` →
    `cloudresourcemanager`, etc. — enumerable from the emitted specs).
- `ProviderFamily` enum: `Google` (only implemented arm); `Aws`/`Azure` parse
  but return `ToolError::Configuration("provider 'aws' not yet implemented")` —
  the cross-cloud seam is explicit, not baked out. A `ProviderBackend` trait
  (Google first) is the internal seam so `aws` → AWS SDK for Rust and `azure`
  → Azure SDK / generated REST attach later without touching the Google path
  or the public YAML.
- `GoogleProvider` owns an `action -> handler` match. Each handler:
  1. builds the REST request (method, URL, body) from `input`;
  2. for `ensure`/`enable` verbs, does a **GET-first idempotency check**
     (describe/list) and short-circuits to `{"changed": false, "existing": …}`
     if already present;
  3. if `dry_run` → returns the planned request as normalized JSON
     (`{"dry_run": true, "would_call": {method, url, body_shape}}`) **without**
     minting a token or calling Google;
  4. else (apply mode) resolves the **explicit `auth:` alias** through the
     keychain/credential path (erroring if absent — see the auth model above),
     mints the bearer token from the resolved credential (ADC-backed
     service-account or the named credential), issues the call, normalizes the
     response.
- **Normalized result** (`ToolResult.data`):
  ```json
  {
    "provider": "google",
    "action": "google.cloudresourcemanager.projects.ensure",
    "dry_run": false,
    "changed": true,
    "resource": { "…normalized google response…" },
    "backend": "rest"
  }
  ```

### 6. Initial Google operation scope → REST mapping (design, not yet coded)

| Action (`action:` value) | HTTP | Endpoint | Idempotency |
| --- | --- | --- | --- |
| `google.cloudresourcemanager.folders.list` | GET | `cloudresourcemanager.googleapis.com/v3/folders?parent=organizations/{org}` | read-only |
| `google.cloudresourcemanager.folders.ensure` | POST `v3/folders` | list under parent → create if display_name absent (LRO) | GET-first |
| `google.cloudresourcemanager.organizations.iam.get_policy` | POST | `v3/organizations/{org}:getIamPolicy` | read-only |
| `google.cloudresourcemanager.organizations.iam.ensure_binding` | POST `:setIamPolicy` | getIamPolicy → add member/role if absent → setIamPolicy w/ etag | read-modify-write w/ etag |
| `google.cloudresourcemanager.projects.describe` | GET | `v3/projects/{project_id}` | read-only |
| `google.cloudresourcemanager.projects.ensure` | POST `v3/projects` | get → create if 404, set `parent` (LRO) | GET-first |
| `google.cloudbilling.projects.link` | PUT | `cloudbilling.googleapis.com/v1/projects/{project_id}/billingInfo` | idempotent PUT (compare current `billingAccountName`) |
| `google.cloudbilling.billing_accounts.iam.get_policy` | POST | `v1/billingAccounts/{id}:getIamPolicy` | read-only |
| `google.cloudbilling.billing_accounts.iam.ensure_binding` | POST `:setIamPolicy` | get → merge → set w/ etag | read-modify-write w/ etag |
| `google.serviceusage.services.list_enabled` | GET | `serviceusage.googleapis.com/v1/projects/{project_id}/services?filter=state:ENABLED` | read-only |
| `google.serviceusage.services.enable` | POST | `v1/projects/{project_id}/services/{service}:enable` | inherently idempotent |

The playbook-emitted action names (`folders.ensure`, `projects.ensure`,
`services.enable`, `billingAccounts.iam.ensure_binding`, … — see
`gcp-org-playbooks/automation/gcp_org/*.yaml`) map 1:1 onto the qualified
`google.<service>.<resource>.<verb>` strings above.

**LRO note:** `projects.create`/`folders.create` return a long-running
Operation that must be polled. MVP polls inline with a bounded timeout
(folder/project creation completes in seconds — acceptable under the
execution-model "few seconds" slot rule). Any op that exceeds the budget is
the correct escalation to the callback/hook pattern (documented as a
follow-up, not built in the MVP).

### 7. Execution-model / rules conformance check

- **Gateway = gatekeeper**: the provider tool runs inside a worker/playbook
  step, never the gateway. Data touch is in the playbook step. ✅
- **Worker = atomic compute**: one action per dispatch, stateless, releases the
  slot; long ops bounded, callback noted for overflow. ✅
- **External subsystem**: Google APIs are external, so
  `data-access-boundary.md` puts them in the "playbook acts as client to
  external system" lane (exactly like the auth/Duffel/Amadeus tools) — a direct
  API call is the right shape; the "server-API-only" rule governs `noetl.*`
  data, not third-party clouds. ✅
- **Secrets/credentials** (`execution-model.md`): ADC / keychain-referenced; no
  billing IDs, OAuth files, SA keys, or tokens in YAML or Git. Billing account
  ID stays a runtime `--set` input (the gcp-org-playbooks already enforce
  this). ✅
- **No credential logging** (`logging.md`): the tool must never log the bearer
  token, the `Authorization` header, or setIamPolicy member payloads. The
  `would_call` dry-run echo carries method + URL + **body shape**, not the
  token. The `noetl-tools` crate has no shared scrubber today (grep found
  none) — the provider tool owns its own request-echo field allowlist. Flagged
  as a Phase B test. ✅
- **`no-default-connection.md`**: **RESOLVED (user decision, §5 auth model):**
  a mutating (apply-mode) action **requires an explicit `auth:` alias**
  resolved via the keychain/credential path — no ambient ADC fallback; omitting
  `auth:` on a mutation is a clear config error, not a silent connection.
  Plan/dry-run mode is credential-free (mints no token). This honors the
  rule's intent — no implicit/default connection for a state-changing call. ✅
- **Observability** (`observability.md`): dispatch span + per-kind metrics
  already fire; `execution_id` on the span. Recommend one added counter in
  Phase B: `noetl_provider_action_total{provider,action,dry_run,outcome}`. ✅

### 8. Design-doc location (Phase A step 4)

The prompt's Phase A step 4 asks to write/update a design doc in the relevant
NoETL docs location. **This session is restricted to read-only inspection +
writing this result file**, so I did NOT write into `repos/tools`,
`repos/docs`, or any wiki submodule (those are product writes and carry
unrelated dirty state I must not disturb). The full design is embedded here.
**Phase B should land the design doc as:**

- `repos/noetl-tools-wiki/Provider-Tool.md` (the tools crate's wiki — sibling
  of `mcp-tool.md`, `nats-tool.md`, `Snowflake-Tool.md`), cross-linked from
  `Home.md` + `_Sidebar.md` per `wiki-maintenance.md` Rule 1/2b, and/or
  `repos/docs/docs/reference/tools/provider.md`;
- plus module-level `//!` docs in `repos/tools/src/tools/provider.rs`;
- with a back-link from `gcp-org-playbooks/docs/noetl-google-api-runtime.md`.

## Phase B — implement MVP locally

**NOT STARTED — gated on wait phrase `implement provider tool`.** No code
written, no tests, no builds, no worker rebuild, no kind validation.

When authorized, the smallest useful path (recommended order):

1. `repos/tools/src/tools/provider.rs` — `ProviderTool` + `ProviderSpec`
   parsing + `ProviderFamily`/`Backend` enums + `GoogleProvider` handler match.
   Start with the 3 read-only actions (`folders.list`, `projects.describe`,
   `services.list_enabled`) + 1 mutating with GET-first idempotency
   (`services.enable`); stub the rest to
   `ToolError::Configuration("<action> not yet implemented")`.
2. `repos/tools/src/tools/mod.rs` — `mod provider; pub use …; registry.register(ProviderTool::new());`.
3. Tests (prompt Phase B.6): spec parsing (both action forms); `dry_run=true`
   returns `would_call` and mints **no** token / makes **no** network call
   (assert with a no-network unit test); **mutating action with `auth:` omitted
   → `Configuration` error and no network call** (the resolved explicit-auth
   decision); unknown provider + unknown action → `Configuration` error;
   **secret redaction** — assert the emitted result/echo never contains a token
   or the `Authorization` header.
4. Sample playbook under `repos/tools/examples/` or an e2e fixture mirroring the
   `gcp-org-playbooks` `folders.list` / `services.enable` specs, `dry_run` only.
5. No real cloud mutation in tests — every network-touching path behind
   `dry_run` or a mocked transport.
6. Kind validation (`deployment-validation.md`): rebuild the worker image, load
   into `kind-noetl`, run the sample playbook in `plan` mode only.

## Phase C — report and integration instructions

**NOT STARTED — depends on Phase B.** No files changed, no commands run beyond
read-only inspection, no branch/SHA to report, no PR. When Phase B lands, Phase
C reports exact files changed, `cargo test`/`clippy` results, which actions
ship vs remain stubbed, and the `repos/tools` branch + commit SHA (no push / no
PR unless explicitly instructed).

## Issues observed

- **Prompt's implementation-target guess (`repos/noetl`, Python) is off.** The
  live tool path is Rust (`repos/tools` + `repos/worker`); Python is scaled to 0
  in prod. A Python provider tool would be dead code. Design retargets to Rust.
- **No shared secret-scrubber in the `noetl-tools` crate.** Redaction today is
  server-side (`scrub::scrub_in_place`) and per-tool. The provider tool must own
  its own request-echo field allowlist — a Phase B test requirement.
- **`dry_run` has no precedent in the tools crate** (grep found none). It's a
  new tool-level concept the provider kind introduces; worth a short note on the
  tools wiki so other kinds can adopt the convention later.
- **Long-running Operations** (project/folder create) need bounded inline
  polling in the MVP; over-budget ops should move to the callback/hook pattern
  (execution-model). Design notes it; MVP assumes seconds-scale completion.
- **Two duplicate Phase A sessions** were started from timed-out retries and
  aborted; this canonical session re-verified the findings and produced this
  authoritative result, overwriting the duplicate's earlier version.

## Manual escalation needed

- **Human go-ahead to start Phase B** — reply with the wait phrase
  `implement provider tool`. Nothing further proceeds without it.
- **Open decision (reversible, defaulted):** MVP ships `runtime: rest` and maps
  `rust-sdk` → REST with a `backend` note, rather than adding the heavy
  `google-cloud-rust` SDK now — say so if you want the real SDK backend in
  round 1 (changes dep footprint + build time materially).
- **RESOLVED during round-01 review (user):** apply-mode mutations require an
  explicit `auth:` alias (keychain/credential path), not ambient ADC. Folded
  into the §5 auth model and the §7 conformance check — no longer open.
- **No credentials were requested or used.** Credential resolution is a Phase B
  runtime concern; nothing to escalate for Phase A.

---
**Confirmation:** Phase B was NOT started. No remote writes, no cloud/GCP
mutations, no state-changing `gcloud`/API calls, no deploys, no worker rebuild,
no kind/prod actions occurred. Read-only inspection of the repos + this result
file only; no unrelated dirty state was touched.
