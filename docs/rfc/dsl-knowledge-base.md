# RFC: A generated, version-aware DSL knowledge base for humans and AIs

- **Status:** Draft. Phase 1 is in review as a server PR. It is flag-gated and OFF by default.
  Nothing is armed in prod and nothing deploys.
- **Date:** 2026-11-07
- **Decision record:** [`docs/decisions/2026-11-07-dsl-kb-generated-from-orchestrate-core.md`](../decisions/2026-11-07-dsl-kb-generated-from-orchestrate-core.md)
- **Coordinates with:** [`interop-topology-and-ai-mcp-playbooks.md`](interop-topology-and-ai-mcp-playbooks.md)
  (ai-meta#539). That RFC owns the MCP endpoint, the topology model and worker `capabilities`
  registration. This RFC **consumes** those and does not redefine them.
- **Related:** noetl/ai-meta#201 (CLI-generated playbook schema), #256 (registration rejects
  unknown tool kinds), #330 (worker noetl-tools hold), #105 (WASM plug-ins), #447 (resource type
  ≠ tool kind), #455 (runtime registry).

Code citations are against `main` on 2026-11-07: server `026212a`, worker `58a2c7a` (v6.11.9),
tools `89302cc` (published 4.4.0; the worker pins `=4.0.1`), cli `3d8c501` (v5.5.0),
ehgraph `3cb4ab3`, docs `202507d`.

---

## 0. Summary

**The goal.** Any AI, ours or a customer's, should be able to ask a running NoETL *"what can I
write right now?"*, generate a playbook from the answer, and have it checked before it is
registered. The answer must be produced from the code that will run the playbook, never from
hand-written docs. noetl.dev should show the same answer to people.

**What exists.**

- The authoritative grammar is a set of Rust types in `noetl-orchestrate-core`.
- A JSON Schema exists, but it is generated from a *different* model (the CLI's
  `noetl-executor`). In that model `tool.kind` is an open `String`.
- Nothing serves either one over the API.

**What is missing.**

1. A schema emitted from the *server's* types, including the live state of the tool-kind gates.
2. A way to answer "which kinds can **execute**", not just "which kinds **parse**". Today these
   differ, and no process can compute the difference.
3. Per-tool input and output schemas. Tool configs are typed in `noetl-tools`, but no schema is
   derived from them.
4. A validator that runs the real parser **before** registration. Today catalog registration
   never calls `parse_playbook`.

**The design** has five parts:

- **Generate.** `schemars` derives on the orchestrate-core authoring types, behind an optional
  feature. A pure `dsl` module builds a manifest from `ToolKind::ALL` and `ToolKindGates`.
- **Stamp.** Every answer carries the server and core versions, the grammar `apiVersion` and a
  SHA-256 of the schema. The digest is the identity of the grammar.
- **Serve.** `GET /api/dsl/{version,schema,tools}` now. `POST /api/dsl/validate` next. MCP tools
  on the interop RFC's endpoint later.
- **Intersect.** Workers report their registered kinds (interop Phase 3 `capabilities`). The KB
  marks each kind as available, accepted but not executable, or gated off.
- **Publish.** Release workflows attach the generated artifacts, and noetl/docs renders them.

**Surfaces.**

- **noetl.dev** is docs only. It is generated from releases.
- **noetl.ai** is served by the new repo **noetl/noetl.ai**. It carries the AI/programmatic face
  (static artifacts, a pass-through `/api/dsl/*`, MCP) and the human face (prompt/spec →
  validated playbook). Both are clients of the same server KB and validator.
  - Its first slice is live on the preview `noetl-ai-kb.pages.dev`.
  - The live domain still serves the noetl/gui landing and waitlist until a gated cutover.
- **noetl/gui** remains the control-plane GUI (`console.noetl.ai`).

**Phase 1** is the server-only slice: emit the schema and tool-kind manifest from
orchestrate-core, add a golden-file guard so it cannot drift, and serve it read-only behind
`NOETL_DSL_KB` (off).

---

## 1. Current state, grounded

### 1.1 The playbook grammar is Rust types in orchestrate-core

`server/orchestrate-core/src/playbook.rs` is the grammar. The server re-exports it
(`server/src/playbook/mod.rs:13`, `pub use noetl_orchestrate_core::playbook as types`), and the
same source compiles to the wasm32 `system/orchestrate` plug-in (`orchestrate-core/src/lib.rs`).

| DSL construct | Type | Location |
|---|---|---|
| Document root (`apiVersion`, `kind`, `metadata`, `workload`, `vars`, `keychain`, `workbook`, `workflow`) | `Playbook` | `playbook.rs:1029` |
| Step (`step`, `desc`, `spec`, `when`, `args`, `vars`, `set`, `loop`, `tool`, `next`) | `Step` | `playbook.rs:854` |
| `tool:` as a single tool or a pipeline (flat `name:` form or nested label-as-key form) | `ToolDefinition`, `PipelineItem` | `playbook.rs:523`, `:571` |
| Tool block (`kind`, `eval`, `auth`, `libs`, `input`/`args`, `code`, `url`, `method`, `query`, `command`, `connection`, `params`, `headers`, `output_select`, plus a flattened `extra`) | `ToolSpec` | `playbook.rs:379`–`492` |
| Eval policy (`expr`, `do: continue\|retry\|break\|jump\|fail`, `attempts`, `backoff`, `delay`, `set_vars`, `target`, `else`) | `EvalCondition`, `EvalElse`, `EvalEntry` | `playbook.rs:329`, `:362`, `:498` |
| Loops (`in`, `iterator`, `spec.mode: sequential\|parallel\|cursor`, `max_in_flight`, `frame`, `cursor.claim`) | `Loop`, `LoopSpec`, `LoopMode`, `FrameSpec`, `CursorClaim` | `playbook.rs:620`–`716` |
| Routing (`next:` as a string, a list, `[{step, when, args}]`, or `{spec:{mode}, arcs:[{step, when, set}]}`) | `NextSpec`, `NextRouter`, `NextArc` | `playbook.rs:733`–`822` |
| Keychain (provider, map, region, residency…) | `KeychainDef`, `Residency` | `playbook.rs:919`, `:21` |

The types derive `Serialize`/`Deserialize` but **not** `JsonSchema`. The grammar is not emitted
in any machine-readable form.

Semantic rules that a type cannot express live in `server/src/playbook/parser.rs`:

- `apiVersion == "noetl.io/v2"` and `kind == "Playbook"`;
- a step named `start` must exist;
- step names must be unique;
- `next` must reference existing steps;
- the `when` syntax check;
- pipelines must be non-empty;
- eval and loop checks.

These are in `validate_playbook` at `parser.rs:164`. `parse_playbook` (`parser.rs:15`) also
rejects the deprecated `case:` blocks and resolves `kind: workbook` references in place.

### 1.2 Tool kinds: a closed enum, with flag gates

- **The enum.** `ToolKind` (`playbook.rs:48`) is a closed `snake_case` enum. `ToolKind::ALL`
  (`:211`) lists all 27 variants, and a test pins that count.
- **The parser.** `ToolKind::parse` uses serde as the oracle, so no second list of names exists.
- **The gates.** Since server#560, `mcp` and `agent` are gated by `NOETL_TOOL_KIND_MCP` and
  `NOETL_TOOL_KIND_AGENT`, through `ToolKindGates` (`:120`). The flags are read once per process.
  A gated kind is refused both by `ToolKind::parse` and by `ToolSpec.kind`'s `deserialize_with`.
- **The error message.** `ToolKind::valid_set()` (`:271`) is the only place the server currently
  *tells* anyone which kinds exist, and only inside a 4xx error message.

### 1.3 Tool input schemas: typed in noetl-tools, but not emitted

- **The interface.** Each tool implements `trait Tool` (`tools/src/registry.rs:175`), which has
  `name()`, `side_effecting()` and `execute(&ToolConfig, …)`. It has no schema method.
- **The config structs.** Tools deserialize their own typed config, for example `HttpConfig`
  (`tools/src/tools/http.rs:47`), `PostgresConfig` (`postgres.rs:21`) and `McpConfig`
  (`mcp.rs:87`). They do this from the flattened `ToolConfig.config` value. **That struct is the
  real input schema of the kind.** Nothing derives a JSON Schema from it.
- **Output.** Output is the generic `ToolResult` plus the kind-specific shape under `data`.
- **The registry.** `create_default_registry()` (`tools/src/tools/mod.rs:94`) registers 20 tools
  at both `v4.0.1` and `main`:

  `shell rhai http duckdb ducklake postgres python snowflake transfer script playbook provider
  noop task_sequence result_fetch artifact container nats mcp subscription`

  `ToolRegistry::list()` (`registry.rs:226`) can enumerate them at runtime.
- **The worker.** The worker builds this registry in `executor/command.rs:260`. With the
  default `wasm-plugin` feature it also routes `kind: wasm` to wasmtime (`command.rs:799`–`823`).

### 1.4 The server accepts a set of kinds; the worker executes a different set

Putting §1.2 and §1.3 side by side:

- **Accepted by the server, but with no tools-registry executor:** `workbook`, `playbooks`,
  `secrets`, `iterator`, `gcs`, `gateway`, `snowflake_transfer`, `wasm` and `agent`.
  - `workbook` is resolved server-side by `parse_playbook`.
  - `wasm` runs in the worker's plug-in host.
  - `agent`'s `AgentTool` is not registered in any release (#330).
  - The others need checking. That check should be a mechanical intersection, not a person
    reading a list.
- **Registered by the worker, but not accepted by the server as an authored kind:** `provider`
  and `result_fetch`.

**This is the #256 defect class in general form.** "It parses" is not "it runs", and today no
process holds both halves:

- **The worker reports nothing.** It registers with `name`, `component_type`, `runtime.kind`,
  `worker_public_key`, `status`, `hostname` and `labels.pool_name`
  (`worker/src/client/control_plane.rs:1138`). It sends no tool kinds, no worker version, no
  noetl-tools version and no feature list.
- **The server can store it but has nothing to store.** `RegisterRuntimeRequest.capabilities`
  already exists (`server/src/services/runtime.rs:113`). The field is simply never filled.

### 1.5 A JSON Schema exists, but from the wrong model

The CLI already emits one. `noetl schema` came from ai-meta#201 (cli commit `879eb89`), uses
`schemars` 1.x behind the optional `json-schema` feature, and is written to
`cli/schema/playbook.schema.json`. Its `$id` is `https://noetl.io/schema/playbook.schema.json`.

That work is valuable. Its validation found real model defects against 279 real playbooks, and
its "permissive by design" stance is right (see §2.2). But the schema is derived from
`noetl-executor`'s document model, not from orchestrate-core:

- `ToolSpec.kind: String` (`cli/executor/src/playbook.rs:1024`), so the schema accepts **any**
  kind name, including kinds the server rejects at registration.
- `next:` is typed `serde_yaml::Value`, so routing is unconstrained.
- It knows nothing about gates, versions or which kinds execute.

So an AI that trusted this schema would be told `kind: totally_bogus_kind` is valid. That is
exactly the hallucination this RFC exists to close.

### 1.6 Registration does not run the parser

`CatalogService::register` (`server/src/services/catalog.rs:55`) does four things:

1. It YAML-parses the document.
2. It validates `kind: Subscription` specs (`:92`).
3. It validates tool kinds against `ToolKind::parse`, via a tree walk (`:107`, `:490`–`606`).
4. It refuses inline secret material (`:115`).

It does **not** call `parse_playbook`. That call happens only at execute time
(`handlers/execute.rs:386`; `handlers/events.rs:3358`, `:3882`, `:4648`). So a playbook with any
of the following registers successfully and fails only when someone runs it:

- no `start` step;
- a `next:` to a missing step;
- a wrong field type;
- a malformed `loop`.

The machinery for a validate-before-register loop already exists. It is just not wired into
registration.

### 1.7 The server's grammar rejects real playbooks that the CLI model accepts

The corpus was every `kind: Playbook` document in fresh clones of e2e and ops, plus the
server's own `tests/fixtures`: 281 documents, measured on 2026-11-07.

- **Result.** orchestrate-core's `Playbook` deserializes **261** of them and rejects **20**.
- **The rejections:**
  - 8 × `ToolDefinition` untagged mismatch;
  - 7 × missing `tool` (steps that only route);
  - 2 × `NextSpec` mismatch;
  - 3 × templated numeric or boolean fields (`lease_seconds: '{{ … }}'`,
    `max_in_flight: '{{ … | int }}'`).
- **Prior art.** ai-meta#201 found and fixed the templated-number class in the *CLI* model
  (`TemplatableI64`/`TemplatableF64`). It was never carried to the server's model.

The generated schema mirrors the server exactly. Validated offline with `jsonschema`
(draft 2020-12), it accepts all 261 documents the core accepts and rejects all 20 it rejects. So
the KB reports the real gap instead of hiding it. Whether the server grammar should widen to
match is a separate decision (§5).

### 1.8 Versions and the plug-in path

- **Versions.** The server reports its own version as `noetl_server_build_info{version}`
  (`metrics.rs:862`). The release workflow stamps `CARGO_PKG_VERSION` from the tag.
  orchestrate-core is published to crates.io first (`release.yml:84`–`110`).
- **Plug-ins.** WASM plug-ins are registered by path and version at
  `POST /api/internal/plugins/{*path}` (`main.rs:750`, `handlers/plugins.rs`), and are
  content-addressed by SHA-256. A plug-in has **no declared input or output schema**: a
  `kind: wasm` step carries `plugin: {path, version}` plus opaque `input`.
- **Docs.** noetl.dev (noetl/docs, Docusaurus) has hand-written DSL pages under
  `docs/reference/dsl/`. Its deploy workflow runs on push to `main` only.

---

## 2. Design

### 2.1 Principle: one source, projected

The knowledge base is a set of **projections of the code**. Each answer comes from the same
code that enforces it:

| Answer | Source (single) | Projection |
|---|---|---|
| Grammar (structure, steps, eval, loop, next) | orchestrate-core types | JSON Schema via `schemars`, behind feature `json-schema` |
| Semantic rules the schema cannot express | `validate_playbook` + `validate_tool_kinds` + the secret scan | the validate endpoint *runs* them; it does not describe them |
| Tool kinds the server accepts | `ToolKind::ALL` × `ToolKindGates::current()` | manifest `tool_kinds[]` (+ the schema's `ToolKind` enum narrowed to the open gates) |
| Tool kinds that can execute now | live workers' registered `ToolRegistry::list()` | intersection computed at request time |
| Per-kind input/output schema | noetl-tools `*Config` structs | `schemars` behind a noetl-tools feature, keyed by tools version |
| Plug-in kinds | plug-in module manifest | registered with the module, served from the catalog |
| Resource kinds (`Playbook`, `Subscription`, `Mcp`, …) | catalog registration dispatch | manifest `resource_kinds[]` |

Nothing in the KB is hand-maintained. The few prose descriptions come from the Rust doc comments
that `schemars` already lifts into `description`.

### 2.2 Generation

**orchestrate-core gains an optional feature, `json-schema = ["dep:schemars"]`.**

- **The derives.** Every *authoring* type in `playbook.rs` gains
  `#[cfg_attr(feature = "json-schema", derive(schemars::JsonSchema))]`. Wire and command types
  (`ToolCall`, `Command`) are not authoring types and get no derive.
- **The wasm plug-in.** `plugins/orchestrate` does not enable the feature, so its size and
  surface are unchanged.
- **The server.** The server enables the feature on its dependency.

**Generation rules, taken from #201's experience:**

1. **Permissive, like the parser.** No `additionalProperties: false`. `ToolSpec` has a
   flattened `extra` map and accepts kind-specific keys. A stricter schema would fail valid
   playbooks and would teach AIs a grammar the server does not have.
2. **Closed where the parser is closed.** `tool.kind` is an enum, because `ToolKind` is one.
   This is the main correction to the #201 schema.
3. **Gates are applied at emit time, not at derive time.** `dsl::playbook_schema(gates)` sets
   `$defs.ToolKind.enum` to `ToolKind::ALL` filtered by `gates.allows`. The schema a server
   serves therefore matches what that server's `ToolSpec.kind` deserializer accepts, flag for
   flag.
4. **Untagged enums keep their variant order.** `NextSpec` and `PipelineItem` become `anyOf` in
   declaration order, which is the order serde tries them.

**The manifest** is a pure function, `dsl::manifest(gates)`, with no schemars dependency. It
returns one entry per `ToolKind::ALL` variant: `name`, `gated`, `gate_env` and `enabled`. It
also returns the grammar's `api_version` and the resource kinds.

**Freshness is enforced, not hoped for.**

- The generated schema and manifest are committed under `orchestrate-core/schema/`.
- A test regenerates both and fails on any byte difference. The failure prints the regenerate
  command (`cargo run -p noetl-orchestrate-core --example emit_dsl --features json-schema`).
- A grammar change that forgets the artifact fails CI. The artifact can never be edited by hand
  and still pass.

### 2.3 Versioning: answer for the running system

A KB response is always stamped:

```json
{
  "api_version": "noetl.io/v2",
  "schema_digest": "sha256:…",
  "server_version": "3.152.0",
  "orchestrate_core_version": "0.1.0",
  "gates": { "NOETL_TOOL_KIND_MCP": false, "NOETL_TOOL_KIND_AGENT": false },
  "generated_at": "process-start"
}
```

**How the stamp is used.**

- `schema_digest` is the identity of the grammar. It is the SHA-256 of the canonical (sorted
  keys) gated schema, and it is the HTTP `ETag`.
- An AI client pins the digest. It sends it back on `validate`, and gets a drift warning if the
  server's grammar has changed since it fetched the schema.
- The gates are read once per process, so the digest is fixed for the life of a process. It
  changes only on a rollout or a flag flip, both of which need a restart.

**"Available right now" is three layers.** Phase 1 ships layer (a) only, and says so in the
response.

- **(a) Accepted.** Kinds this server's parser accepts. Pure and exact (Phase 1).
- **(b) Executable.** (a) ∩ the union of `tool_kinds` reported by **live** workers. "Live" means
  the runtime-registry lease, not a status column. The intersection is computed per pool, so
  "`duckdb` runs only on the `analytics` pool" can be answered.
  - Each kind gets one of: `available`, `accepted_not_executable`, `gated_off` or
    `executable_not_accepted`. The last is a diagnostic, for example `provider`.
  - Workers report `capabilities = { worker_version, tools_version, features: [...],
    tool_kinds: registry.list(), tool_schema_digests: {...} }` at register time. This is the
    interop RFC's Phase 3 "register `capabilities`". The KB is its first consumer, so the shape
    is agreed there rather than invented twice.
- **(c) Components.** The versions of server, worker(s), noetl-tools, cli (when a CLI runtime
  registers, interop Phase 3) and embedded ehgraph.
  - The server learns its own dependency pins (ehgraph, ehdb, orchestrate-core) at build time
    from `Cargo.lock`, through a build script.
  - The rest comes from registrations.

Until (b) ships, `/api/dsl/tools` returns `"executable": "not_reported"`. It never returns a
guess.

### 2.4 API

Everything is under `/api/dsl/`. These are read-only reflections of code, with no tenant data
and no secrets, in the same exposure class as `/api/health`. The gateway proxies the routes to
external callers as `/noetl/dsl/*` under its normal authentication.

| Method & path | Phase | Returns |
|---|---|---|
| `GET /api/dsl/version` | 1 | The version stamp (§2.3) |
| `GET /api/dsl/schema` | 1 | The gated playbook JSON Schema (draft 2020-12), with `ETag: <digest>` |
| `GET /api/dsl/tools` | 1 | Tool-kind manifest: per kind `{name, gated, gate_env, enabled, executable}` + resource kinds |
| `GET /api/dsl/tools/{kind}` | 3 | The kind's input/output schema + examples from the worker-reported tools version |
| `POST /api/dsl/validate` | 2 | Dry-run registration (body = a playbook, YAML or JSON). Runs exactly the register path minus the insert, **plus** `parse_playbook`. Returns `{valid, errors:[{path, step, message, rule}], warnings, schema_digest}`. No DB write and no event. |
| `GET /api/dsl/manifest?format=llm` | 4 | A compact text rendering of the above (llms.txt style) for prompt context |

**Validation errors are designed for a machine to repair.** Each error carries:

- a JSON-pointer `path` (for example `/workflow/3/tool/kind`);
- the step name;
- a stable `rule` id (`unknown_tool_kind`, `gated_tool_kind`, `missing_start_step`,
  `dangling_next`, `inline_secret`, `schema`);
- a human message.

`gated_tool_kind` names the flag. `unknown_tool_kind` lists the valid set.

### 2.5 The validation loop, closed

1. **Generate.** An AI fetches `/api/dsl/schema` (and `tools/{kind}`) and generates a playbook.
2. **Validate.** It calls `POST /api/dsl/validate`, repairs the listed errors, and repeats until
   `valid`.
3. **Register.** It registers.

**Registration converges with validate** (Phase 2), behind
`NOETL_CATALOG_PARSE_ON_REGISTER=off|shadow|enforce`, default `off`:

- `shadow` runs `parse_playbook` for `kind: Playbook` entries and records a would-reject metric
  labelled by `rule`. It rejects nothing.
- `enforce` makes registration fail exactly where validate fails.

Shadow comes first because the live catalog has rows that register today and would not parse.
#256 already found unexecutable rows. Shadow puts a number on how many, before anything is
refused. The CLI's `noetl validate` gains `--server <url>`, which calls the endpoint instead of
its local model.

### 2.6 LLM- and agent-facing

The KB is plain HTTP and JSON, so any agent can use it on day one. On the MCP endpoint that the
interop RFC defines (`POST /api/mcp`, its Phase 5, flag `NOETL_MCP_SERVER`), the KB is exposed as
**fixed helper tools**, next to `noetl.execution.*`:

- `noetl.dsl.describe`: the version stamp + manifest (layer b when available).
- `noetl.dsl.schema`: the gated grammar, or one kind's tool schema.
- `noetl.dsl.validate`: the dry-run validator.

It is also exposed as MCP **resources** (`noetl://dsl/schema`, `noetl://dsl/tools/{kind}`), so a
client can attach them as context. The flow becomes *"ask what's available, then generate, then
validate, then register"*, all inside one MCP session.

Two rules from the interop RFC carry over:

- The helper tools are listed regardless of `may_execute`, because they reveal grammar, not
  data.
- `validate` never executes anything.

NoETL's own agents (`kind: agent` playbooks, interop Phase 6) get the same tools in their tool
set. The guardrail applies to internal and external generators alike.

### 2.7 noetl.dev publishing

- **Per release.** The server and tools release workflows attach the generated artifacts
  (`playbook.schema.json`, `dsl-manifest.json`, and from Phase 3 `tool-schemas.json`) as release
  assets, versioned by tag.
- **The docs job.** noetl/docs gains a `repository_dispatch` + nightly job. It pulls the latest
  release assets and renders them with a small generator into
  `docs/reference/dsl/generated/{grammar,tool-kinds,tools/<kind>}.md`, including a version
  table. It opens an automated PR; a merge deploys through the existing Cloudflare Pages
  workflow.
- **Hand-written vs generated.** The hand-written DSL pages stay as tutorials and link to the
  generated reference. The generated pages carry a "generated from server vX / tools vY — do not
  edit" banner.
- **The canonical schema URL.** The schema is also served statically at
  `https://noetl.ai/schema/v2/playbook.schema.json` (noetl.ai is the machine-readable home, §2.8; noetl.dev only renders the human view) (plus `…/<server-version>/…`). The `$id`
  becomes that URL. The CLI's `noetl schema` converges on the same artifact (Phase 4): it depends
  on `noetl-orchestrate-core` with `json-schema` instead of emitting from its own model. A
  cross-check test asserts the CLI document model accepts a superset of what the core accepts.

**Production versions and doc versions.** The published page reflects *released* versions. The
API reflects the *deployed* system. Both carry the same digest, so "is prod on the documented
grammar?" is a string compare.

### 2.8 Surfaces by domain: noetl.dev for docs, noetl.ai for the service and generation

- **noetl.dev** stays **documentation only**. It renders the human-readable reference generated
  from release artifacts (§2.7) and links to noetl.ai for anything interactive or programmatic.
- **noetl.ai** is the canonical home of the **programmatic and AI surface**, and of the **human
  generation surface**. Both are clients of one KB and one validator, the server's
  `/api/dsl/*`, so they cannot drift.

**What is live at noetl.ai today.** This was checked read-only on 2026-11-07, in Cloudflare
account `52576681…8655`. The Pages projects are direct-upload, with no Git integration.

| Host | Pages project | Source (deployed commit) | What it is |
|---|---|---|---|
| `noetl.ai`, `www.noetl.ai` | `noetl-ai` | **noetl/gui** `landing/` (commit `80b7f11`, PR #49), deployed with `./stamp.sh && wrangler pages deploy public --project-name noetl-ai` | Anonymous landing page. It has a **simulated** text→playbook "forge" (`forge.js`, canned replies, no network), simulated domain demos, and waitlist/feedback chat forms. The forms post to the site's own Pages Functions (`functions/api/{waitlist,feedback}.js`), which store to **KV**. By design the bundle contains no NoETL API client (`landing/README.md`, "Why this is a separate app"). |
| `console.noetl.ai` | `noetl-console` | **noetl/gui** Vite/React app (commit `7d23dee`) | The authenticated NoETL dashboard: catalog, Monaco editor, ReactFlow designer, executions, EHDB, and a **live chat** (`/travel`, `GatewayAssistant` + `NoetlPrompt`). It calls `VITE_GATEWAY_URL=https://gateway.mestumre.dev`, the gateway in front of the GCP/GKE NoETL deployment, and executes `automation/agents/travel/runtime` with SSE. |

**Firestore.** The chat's data belongs to the **travel/Adiona playbooks** (noetl/travel). They
write through `mcp/firestore` on the worker service account, into `chat_threads/**`, `trips/**`
and `users/**`. Browser access is denied by `firestore.rules`. Neither noetl.ai project talks to
Firestore directly.

**Decision (2026-11-07): the home is a new repo, noetl/noetl.ai** (ai-meta submodule
`repos/noetl.ai`).

- **noetl/gui** stays the deployable GUI of the **control plane** (`console.noetl.ai`, the
  dashboard on the GCP gateway). It is not part of this plan.
- **The landing page.** The gui `landing/` coming-soon and waitlist page is the **placeholder**
  that noetl/noetl.ai eventually replaces, through a gated cutover (below).
- **"NoETL cloud"** (the productized customer cloud) is a separate future product on its own
  domain, and is out of scope here.

noetl/noetl.ai keeps the landing page's load-bearing property: an anonymous page carries no
client that can execute anything. It deploys in the same way (no bundler, `public/` +
`functions/`, wrangler direct upload) and to an **isolated preview project, `noetl-ai-kb`**
(`noetl-ai-kb.pages.dev`), until cutover.

1. **The AI and programmatic face** (first slice is live on the preview).
   - **Static and anonymous-safe.** `public/schema/v2/playbook.schema.json`,
     `public/dsl/manifest.json`, `public/dsl/source.json` (the server commit and digests) and
     `public/llms.txt`.
     - `scripts/sync-artifacts.sh <server-ref>` copies them from a pinned noetl/server commit.
       They are never hand-edited.
     - The digest is computed exactly as `dsl::digest` computes it. This is verified: the Python
       and Rust digests are byte-identical, `sha256:de6519f1…`.
   - **Live.** Pages Functions pass `/api/dsl/{version,schema,tools,validate}` through, read-only
     (`functions/_upstream.js`), to `NOETL_DSL_UPSTREAM`, the gateway base exposing the
     server's `/api/dsl/*`.
     - When unset, they answer `503 upstream_not_configured`. They never fall back to the copy.
     - They forward no cookies or credentials.
     - `validate` has a 256 KB body cap. An edge rate limit comes in Phase 5.
   - **MCP.** `POST /mcp` serves `initialize` / `tools/list` / `tools/call` for
     `noetl.dsl.describe` and `noetl.dsl.schema`, backed by the live server. `noetl.dsl.validate`
     is added with Phase 2. When the interop RFC's server `/api/mcp` lands, these tools move
     there and `/mcp` becomes a proxy to it.
2. **The human generation face** is built **in noetl/noetl.ai**, not in the console. Its first
   slice is a KB explorer page: the version stamp, the tool kinds, and live-vs-static digest
   agreement. The generation box is present but disabled until the validator exists.
   - **How a turn works:** prompt or spec, then grounding on `/api/dsl/schema` + `/tools`, then
     generation, then `POST /api/dsl/validate`, then repair until valid.
     - Generation runs server-side as a NoETL playbook (`automation/agents/dsl/generate`,
       dogfooding `kind: agent`/`http`), reached through the same upstream.
     - The browser never holds a model key.
   - **What the person sees.**
     - The UI shows the `schema_digest` and the tool kinds the answer drew from.
     - The person edits in place, and every edit re-validates through the same endpoint.
     - A playbook is never shown as valid without a validate pass at the current digest.
     - Registering is a separate, explicit, authenticated action.
   - **History.** If kept, history persists through a playbook, the way the travel chat writes
     Firestore through `mcp/firestore`. There is no browser-side store.
   - **Access.** Anonymous visitors get grounding and validation; generation is rate-limited.
     Both are decided in Phase 6.

**Domain cutover (gated, not done).** `noetl.ai` / `www.noetl.ai` stay on the `noetl-ai` project
(the gui landing page) until the user approves the cutover. That project is live and collects
signups into the `WAITLIST` KV namespace. The procedure is
`noetl.ai/docs/cutover.md`:

1. Port the waitlist and feedback Functions, and bind the same KV, or keep the landing on a
   subdomain.
2. Deploy into `noetl-ai` (no DNS change, one-click rollback), or move the custom domains to
   `noetl-ai-kb`.
3. Set `NOETL_DSL_UPSTREAM`, which needs `NOETL_DSL_KB=true` on a server, a separate approval.
4. Verify that the digests agree and that a waitlist signup round-trips.

`scripts/deploy.sh` refuses the `noetl-ai` project unless `NOETL_AI_CUTOVER=approved`.

**Version sync.** Both faces read the stamp from the server they proxy, and the static
artifacts come from the release that produced that server. A mismatch between the static digest
and the live one is shown, not hidden. It means the docs or the static assets lag the
deployment.

### 2.9 Extensibility: a new tool kind or plug-in appears everywhere at once

**A native tool kind.** It is a PR series that the KB makes visible at every stage:

1. **noetl-tools.** Add the `Tool` implementation, its `*Config` struct with
   `derive(JsonSchema)` (feature `json-schema`), and `examples/<kind>.yaml`. Register it in
   `create_default_registry`.
2. **orchestrate-core.** Add the `ToolKind` variant, **gated and OFF by default** (the
   server#560 pattern). Add it to `ToolKind::ALL`. The count test forces the update, and the
   golden schema test forces the regenerated artifact.
3. **Worker bump.** The new worker reports the kind in `capabilities`.

At each step the KB states the truth:

- After 2 and before 3, the kind is `gated_off`, then `accepted_not_executable` once the gate is
  open.
- After 3 it is `available`.
- Docs regenerate on release.

So "AIs can use it immediately" means *immediately after it can actually run*, and no sooner.
That is the #256 lesson.

**A plug-in kind (WASM).** This is the path for third-party extensions without a server release.

- **The manifest.** A plug-in module is registered at `/api/internal/plugins/{path}` with a
  manifest (`noetl.plugin.json`, a custom section or a sidecar):
  `{name, version, input_schema, output_schema, capabilities_required, description, examples}`.
- **Discovery.** The KB lists registered plug-ins as `wasm` sub-kinds (`wasm:<path>@<version>`)
  with their schemas.
- **Validation.** The validator checks that `plugin: {path, version}` exists, and that `input`
  conforms to the plug-in's `input_schema`.
- **Isolation.** The capability ring the worker already enforces is unchanged.

**Requesting a kind.** A `tool-kind-request` issue template in noetl/tools records the use case,
the input and output shape (as a JSON Schema draft), the side-effect class and the required
capabilities. The JSON Schema draft becomes the `*Config` struct, so the request is the first
draft of the KB entry.

---

## 3. Why this strengthens the IonQ demo and the AI-as-guardrail story

**The demo.** The quantum demo has a customer's AI generate orchestration playbooks: compile,
optimize, verify, submit. For that, the AI must emit *only* kinds, fields and routing that the
deployed NoETL runs.

- **Before.** The best available schema accepts any `kind`, and registration does not parse.
  A hallucinated step registers cleanly and fails in front of the customer.
- **After.**
  - The AI grounds on `/api/dsl/schema`, which is the deployed grammar with its digest.
  - It checks executability on `/api/dsl/tools`: "is `container` available on the `quantum`
    pool?"
  - It self-corrects against `validate`'s rule-tagged errors before anything registers.

**The guardrail.** In this story the AI is fenced by the platform's own parser, not by prompt
engineering. Every generated playbook passes the same code path the executor runs. A reviewer
can audit the fence by its digest. Extending the fence (a new quantum tool kind or plug-in) is a
schema change that shows up in the API, the docs and the agent's tool list at the same moment.

---

## 4. Phased plan

Each phase is independently shippable and flag-gated OFF, and none arms prod.

| Phase | Slice | Repo(s) | Flag | Tests |
|---|---|---|---|---|
| **1** | orchestrate-core `json-schema` feature + `dsl` module: the gated schema and the tool-kind manifest. Committed artifacts + a golden freshness test. Server `GET /api/dsl/{version,schema,tools}`, read-only, stamped, ETag. | server | `NOETL_DSL_KB` (off: routes not mounted → 404) | golden schema/manifest byte-equality; schema `ToolKind` enum == `ToolKind::ALL` under ALL_ON and hides gated kinds under OFF; digest changes iff gates change; manifest ≡ `ToolKind::parse_with` oracle; ETag/304; flag strict; route in `PUBLIC_BY_DESIGN`. Corpus agreement (§1.7) measured offline in the PR, and becomes a CI test with the Phase 2 validator |
| 2 | `POST /api/dsl/validate` (dry-run register + `parse_playbook`, rule-tagged errors). `NOETL_CATALOG_PARSE_ON_REGISTER=off\|shadow\|enforce` with a would-reject metric. CLI `noetl validate --server`. | server, cli | `NOETL_DSL_KB`, `NOETL_CATALOG_PARSE_ON_REGISTER` (off) | validate ≡ register verdict on a corpus; no DB write; shadow never rejects; one test per rule id |
| 3 | Worker `capabilities` (rides interop Phase 3): tool kinds, versions, features, schema digests. noetl-tools `json-schema` feature on `*Config` + examples. Server intersection → `executable`; `GET /api/dsl/tools/{kind}`; build-time dependency pins (ehgraph/ehdb). | tools, worker, server | worker `NOETL_WORKER_REPORT_CAPABILITIES`, server `NOETL_DSL_KB` | an expired lease drops a kind to `accepted_not_executable`; per-pool intersection; digest mismatch flagged |
| 4 | Publishing: release assets; **noetl.dev** (docs only) generator + dispatch/nightly PR job; `?format=llm`; CLI `noetl schema` converges on core + a superset cross-check. | server, tools, docs, cli | none (docs) | the generator is deterministic; the docs build passes; CLI ⊇ core on the corpus |
| 5 | **noetl.ai, AI face:** static artifacts (`/schema/v2/…`, `/dsl/manifest.json`, `/llms.txt`) published per release; `noetl.ai/api/dsl/*` Pages Functions that proxy read-only to gateway `/noetl/dsl/*`; edge rate limit on validate. Plus MCP: `noetl.dsl.{describe,schema,validate}` + `noetl://dsl/*` on the interop Phase 5 endpoint. | **noetl/noetl.ai** (first slice live on preview `noetl-ai-kb`), gateway, server | `NOETL_MCP_SERVER` (interop's); the proxy is deployed only once Phase 2 is on in the target env | the static digest equals the live digest after a release; the proxy never forwards a non-`dsl` path; an MCP session can list, fetch, validate and register; validate never executes |
| 6 | **noetl.ai, human face:** prompt/spec → playbook UI in noetl/noetl.ai. A `automation/agents/dsl/generate` playbook (server-side, through the same upstream) runs grounding → generation → validate-repair; the UI shows the digest and kinds used; editing re-validates; register is explicit and authenticated. | noetl.ai, ops/playbooks, server | the generation box ships disabled; enabled only after Phase 2 is on upstream | a generated playbook is never shown as valid without a validate pass at the current digest; an edit invalidates the badge until re-validated; the browser holds no model key |
| 6b | **noetl.ai domain cutover** (gated, user-approved): waitlist/feedback + `WAITLIST` KV carried over, or the landing moved to a subdomain; deploy into `noetl-ai` or move the domains. | noetl.ai, Cloudflare | `NOETL_AI_CUTOVER=approved` on the deploy script | digest agreement live vs static; a waitlist round-trip; rollback to landing deploy `80b7f11` |
| 7 | Plug-in manifests: `noetl.plugin.json` at module registration; `wasm:<path>@<ver>` in the KB; `input` validated against the plug-in schema. `tool-kind-request` template. | server, worker, tools | `NOETL_PLUGIN_MANIFESTS` | a plug-in without a manifest stays opaque (back-compat); a malformed input is rejected at validate |

**Why Phase 1 is the smallest safe slice.**

- It is one repo, and the endpoints are read-only and stateless (no DB, no events).
- With the flag off, no route is mounted. The only always-on change is a compile-time derive
  behind a feature, and it changes no runtime behaviour.
- It produces the artifact every later phase consumes, and the golden test makes it impossible
  to forget to regenerate.

---

## 5. Open questions

1. **Exposure.** Should `/api/dsl/*` sit behind the gateway's authentication for external
   callers only (proposed), or also behind the internal auth gate in-cluster? The content is
   grammar, not data.
2. **Strictness.** Should the served schema ever be strict (`additionalProperties: false` per
   kind) once per-kind schemas exist? A proposal: keep the document schema permissive, and offer
   a strict "generation profile" schema for AIs, so they generate a subset of what parses.
3. **Lagging artifacts.** If `cli/schema/playbook.schema.json` is kept during convergence,
   should its `$id` move now, to stop two artifacts claiming one URL?
4. **The 20 rejected playbooks (§1.7).** Should orchestrate-core adopt the CLI model's
   templatable numerics and tool-less routing steps? That would be a grammar widening, with its
   own PR and its own regenerated artifact. Or are those fixtures stale?
5. **The executable layer for CLI-only runs.** Local `noetl run` has no worker. Should the CLI
   report its own registry as a runtime?
