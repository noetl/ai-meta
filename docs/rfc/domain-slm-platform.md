# RFC: Domain-Specific SLM Platform — build + continuously improve org SLMs via NoETL playbooks (MLOps-as-playbooks)

- **Status:** Draft (design only — no model trained, no infra stood up, no prod change)
- **Home:** `noetl/ai-meta` (platform umbrella). Wiki: [Umbrella — Domain-Specific SLM Platform](https://github.com/noetl/ai-meta/wiki/Umbrella-Domain-SLM-Platform).
- **Tracking umbrella:** noetl/ai-meta#139 (children: Phases A–D + platform foundations G1/G2/G3 + registry + experiment store + continuous-improvement loop — see §9).
- **Reference implementation:** noetl/travel#63 (the travel-domain SLM) — the worked example that proves this framework end-to-end. This RFC is the **generalization** of [`repos/travel/docs/rfc/travel-slm.md`](https://github.com/noetl/travel/blob/main/docs/rfc/travel-slm.md).
- **Builds on:** noetl/ai-meta#104 (event-WAL + derivable result tier — the registry's blob substrate), noetl/ai-meta#107 (distributed-OS program — the execution substrate), the platform-gap seeds noetl/travel#70/#71/#72.
- **Scope of this document:** turn the one-off travel-SLM MLOps pipeline into a **reusable, config-driven framework any organization can instantiate** to (a) stand up a domain-specific Small Language Model for its own domain + tools, and (b) keep it continuously improved by a scheduled, playbook-driven loop. **No training, no infra, no prod/IAM/secret change is performed by this RFC.**

---

## 1. Motivation — "tooling for organizations", not a one-off

The travel-SLM work (noetl/travel#63) proves a thesis: an organization can replace a frontier-model API on a narrow, high-frequency task with a small, domain-specialized model that is cheaper, lower-latency, dependency-free, and at least as accurate **on that task** — and it can run the *entire* model lifecycle (dataset → train → eval → serve → shadow → cutover → retrain) as NoETL playbooks, event-sourced and replayable like any other workload.

What travel does by hand, every organization should be able to do **by configuration**. The thesis generalizes:

1. **Most production LLM spend is on narrow tasks.** Intent extraction, tool routing, structured-output generation, classification, summarization-to-schema — each is a fixed I/O contract, not open-ended chat. A small fine-tuned model wins on cost/latency for *exactly* these.
2. **The lifecycle is the same shape across domains.** Bootstrap labels from a teacher model + a deterministic oracle, schema-validate, fine-tune small, grammar-constrain decoding, eval against a floor and a ceiling, serve in-cluster, shadow live traffic, gate the cutover, retrain on a schedule. Only the **contract** and the **data** differ.
3. **NoETL already is the orchestration substrate.** The ephemeral-blueprint execution model (gateway / worker / playbook / cache / event-log) runs the lifecycle for free; the same observability, replay, and data-access discipline apply. We do not need a separate MLOps stack — we dogfood the platform.

So the deliverable is **a parameterized template pack + the missing platform primitives + a continuous-improvement engine**, packaged so an org adopts it by filling in a config, not by writing a pipeline. Travel is the first tenant of that framework.

This RFC is **design + tracking only**. It defines the org-facing config surface, the generic `slm/<stage>` template pack, the continuous-improvement loop and its gates, the domain-agnostic platform foundations (generalizing travel #70/#71/#72), the multi-tenancy/governance model, the packaging/plugin approach, and the phased plan with success criteria — plus the open productization decisions for the platform owner.

---

## 2. The generalized template pack — `automation/mlops/slm/<stage>`

### 2.1 From `travel-slm/<stage>` to `slm/<stage>`

The travel RFC (§6A) defines seven per-stage playbooks under `automation/mlops/travel-slm/`. The generalization extracts each into a **domain-agnostic template** under `automation/mlops/slm/` that is **instantiated by config**, plus a thin per-domain instance that supplies only the contract + data + targets.

| Travel playbook (`automation/mlops/travel-slm/…`) | Generic template (`automation/mlops/slm/…`) | What stays the same (framework) | What the org supplies (config) |
|---|---|---|---|
| `dataset_build` | `slm/dataset_build` | corpus-replay loop, teacher fan-out, oracle cross-check, schema-validate, dedup, dataset registration | I/O contract schema(s), teacher model(s) + prompts, data sources (event-log replay scope, seed corpus, curated/adversarial sets), the optional deterministic oracle playbook |
| `finetune` | `slm/finetune` | resolve-dataset → GPU job dispatch → long-async wait → collect adapter → register model+lineage+metrics | base-model family/size, train recipe (LoRA/QLoRA hyperparams), role layout (one-model-multi-role vs N models) |
| `eval` | `slm/eval` | resolve model+eval set → run inference → compute metrics vs floor+ceiling → gate → register eval | metric definitions + target thresholds, the floor oracle, the ceiling (teacher), the held-out + golden-replay eval sets |
| `shadow_eval` | `slm/shadow_eval` | aggregate shadow-diff events (via server API) → match-rate/latency on live traffic → report | which engine flags emit the shadow-diff event; the diff/equivalence function for this contract |
| `package` | `slm/package` | resolve model → merge/quantize job → write artifact → register serving-ready release | quantization target (GGUF/AWQ/…), serving image recipe, grammar/schema to bake into decoding |
| `deploy` | `slm/deploy` | resolve release → rollout (ops automation, kind-validate) → smoke → flip serving flag → verify; rollback = re-flip | serving target (CPU/GPU stack), the flag(s) to flip in the consuming playbook, smoke probes |
| `retrain_orchestrator` | `slm/retrain_orchestrator` | scheduled compose: capture → drift-check → conditional retrain → eval → package → gated shadow → gated promote | schedule cadence, retrain-trigger gates, promotion gates (§4) |

Plus two **new** generic stages the continuous-improvement loop needs (travel implies them; the framework makes them first-class):

| New generic template | Role |
|---|---|
| `slm/traffic_capture` | Sample production turns (inputs + active-engine outputs + outcome signals) through the server API into the dataset/experiment store, with PII redaction policy. The feedstock for relabel + drift. |
| `slm/drift_monitor` | Scheduled quality/drift evaluation on captured traffic; emits the drift signal that the retrain orchestrator gates on. |

### 2.2 The org-facing config surface (this is what makes it "tooling")

An org instantiates a domain SLM by writing **one config object** (a NoETL workload/resource — a catalog entry, not code). The framework supplies everything else. The config is the contract between "what an org provides" and "what the framework supplies".

```yaml
# automation/mlops/slm/<domain>/slm.config.yaml   (the org writes THIS; the framework runs the templates)
slm_domain:
  name: travel                          # registry namespace + flag prefix + service name
  description: "Intent + tool-routing + widget generation for the Muno planner"

  # ── 1. I/O CONTRACT — the task the model performs (the labeling oracle's spec) ──
  roles:                                # one or more passes the model performs
    - id: extract                       # role token / system-prompt selector
      input_schema:  contracts/extract_input.schema.json
      output_schema: contracts/extract_output.schema.json
      system_prompt: prompts/extract.md
      decoding_grammar: contracts/extract_output.schema.json   # grammar-guided decode (schema or GBNF)
      deterministic_oracle:             # optional second oracle + safety fallback (the "deterministic engine")
        kind: playbook
        path: automation/agents/deterministic/extract
    - id: render
      input_schema:  contracts/render_input.schema.json
      output_schema: contracts/render_union.schema.json        # e.g. the widget-envelope union
      system_prompt: prompts/render.md
      decoding_grammar: contracts/render_union.schema.json
  # tool / routing / widget vocab the contract closes over (the enums grammar enforces)
  vocab:
    tools:   contracts/tool_catalog.json     # exact tool-ids the model may emit
    outputs: contracts/widget_types.json     # exact output/widget types

  # ── 2. DATA SOURCES — where labels come from ──
  data:
    event_log_replay:                   # real production traffic (event-sourced → replayable)
      scope: "tenant=<org>/project=<domain>"
      via: server_api                   # data-access boundary: noetl.* via server API only
    seed_corpus:   datasets/seed/        # curated synthetic coverage per intent/event-type
    adversarial:   datasets/adversarial/ # hand-authored hard cases
    redaction_policy: policies/pii_redaction.yaml   # applied at capture + dataset build

  # ── 3. TEACHER(S) — the labeling ceiling ──
  teachers:
    - id: primary
      kind: http                        # external subsystem (Claude / OpenAI / Vertex / local large) — keychain alias
      credential: "{{ teacher_token }}"
      model: "claude-opus-4-8"          # or gpt-4o, gemini-*, an in-house large model, …
      role_prompts: { extract: prompts/teacher_extract.md, render: prompts/teacher_render.md }

  # ── 4. MODEL / TRAIN — what gets fine-tuned ──
  model:
    base_family: qwen2.5                # qwen2.5 | llama-3.2 | phi-3.5 | smollm2 | …  (see open decision 3)
    base_size: "1.5B"
    recipe: lora                        # lora | qlora | full
    hyperparams: recipes/lora.yaml
    role_layout: single_multitask       # single_multitask (role token) | per_role

  # ── 5. EVAL — the gates ──
  eval:
    floor: deterministic_oracle         # must beat the deterministic baseline
    ceiling: teacher.primary            # measured against the teacher
    metrics:                            # per-domain; name → definition + target (§4 of the per-domain eval)
      - { id: tool_match,      target: 0.98 }
      - { id: arg_fidelity,    target: 0.95, schema_valid: 1.0 }
      - { id: output_validity, target: 1.0,  enforced_by: grammar }
      - { id: latency_p95_ms,  target_relative: "<= ceiling" }
    eval_sets: { holdout: datasets/eval/holdout/, golden_replay: datasets/eval/golden/ }

  # ── 6. SERVING — where the model runs ──
  serving:
    target: cpu                         # cpu (llama.cpp/ollama) | gpu (vLLM/TGI)   (open decision 2/7)
    quantization: gguf
    consuming_playbook: playbooks/itinerary-planner.yaml   # where the flags live
    engine_flags:                       # the flags slm/deploy flips for the gated cutover
      extract: extraction_engine        # openai|slm|deterministic
      render:  render_engine

  # ── 7. CONTINUOUS IMPROVEMENT — the loop cadence + gates ──
  improvement:
    capture: { sample_rate: 0.1, outcome_signals: [user_correction, tool_error, abandonment] }
    schedule: "0 3 * * 0"               # weekly drift+retrain consideration
    retrain_triggers:   policies/retrain_gates.yaml    # §4.1
    promotion_gates:    policies/promotion_gates.yaml  # §4.2
    governance: { registry_namespace: "<org>/<domain>", cost_budget: budgets/<domain>.yaml }
```

**Division of labor, stated plainly:**

- **The org provides** (the seven blocks above): the I/O contract schemas + prompts + vocab enums, its data sources + redaction policy, its teacher credential, base-model + recipe preferences, its eval metrics + targets + eval sets, its serving target + the consuming playbook's flags, and its improvement cadence + gates + budget. All of it is **declarative config + schemas + prompt files** — no pipeline code.
- **The framework provides** (the `slm/<stage>` templates + the platform foundations G1–G3 + the registry + the loop engine): every stage's step DAG, the teacher fan-out + oracle cross-check + schema-validation, GPU-job dispatch + long-async wait, artifact storage + the versioned registry, metric computation + gating, deploy + flag-flip + rollback, traffic capture + drift + scheduled retrain, and the observability/data-access/secrets compliance on every stage.

The test of this RFC's success: **a second domain (e.g. a support-ticket router, or a finance-doc extractor) stands up its SLM by writing one `slm.config.yaml` + its schemas/prompts/seed-data and running the same templates — with zero changes to the framework playbooks or platform tools.**

---

## 3. Platform foundations — generalize travel #70/#71/#72 into first-class NoETL features

Travel flagged three NoETL runtime capability gaps (#70/#71/#72) as travel-scoped. They are not travel-specific — **any** playbook-based MLOps (and many non-ML workloads) needs them. This RFC promotes them to **domain-agnostic platform features** with their own ai-meta issues, and adds three more the continuous-improvement loop requires.

| ID | Feature | Generalized from | Lands in | Built on |
|---|---|---|---|---|
| **G1** | **Container / GPU k8s-Job dispatch tool kind.** A new tool kind that submits a Kubernetes Job (or container) with a node-selector + GPU resource request + mounts, returns a job handle, surfaces status. Domain-agnostic: any heavy/isolated batch compute (train, quantize, large ETL, render farm). | travel#70 | `noetl/tools` (new kind, e.g. `job`/`container`) + `noetl/worker` (dispatch+status) + `noetl/ops` (GPU node pool + RBAC to create Jobs) | execution-model callback rule |
| **G2** | **Long-running async job orchestration.** Callback/webhook + poll/watch fallback + long-timeout resume so a playbook continues when an hours-long Job finishes **without holding a worker slot**. Generalizes the callback/hook pattern in `execution-model.md` to job-scale waits. | travel#71 | `noetl/server` (callback resume) + `noetl/worker` (job watch) | execution-model §callback/hook; pairs with the container-tool-callback umbrella #43 |
| **G3** | **Large-artifact storage + a versioned model/dataset/eval REGISTRY as a NoETL catalog resource kind.** GB-scale blob put/get **plus** registry entries (`model` / `dataset` / `eval` / `release`) with metadata, metrics, lineage pointers, and an object-store URN. Built directly on the #104 result tier (URN-addressed Feather/GCS) — the registry is "the result tier with a typed catalog index + versioning on top". | travel#72 | `noetl/server` (catalog resource kind + blob tool) + `noetl/noetl` | **noetl/ai-meta#104** result tier; resource-locator URN scheme |
| **G4** | **Experiment / eval-metrics store.** A queryable record of every eval/shadow run: metrics over time, per-version, per-domain — so "is the new model better than the incumbent?" and "is quality drifting?" are queries, not log-greps. The metrics live as events/results (per observability.md: metrics over logs); G4 is the typed index + comparison API over them. | new (implied by travel §7 + §6A.1 eval/shadow) | `noetl/server` (experiment resource kind + query API) | G3 registry; observability.md |
| **G5** | **Model lineage / provenance.** Every registered model carries: which dataset version (which capture window + teacher + oracle), which base model, which recipe, which eval run promoted it, which release deployed it. A DAG, queryable, so any production prediction is traceable to its training inputs (audit + reproducibility + rollback target selection). | new (implied by travel §6A "register_model: version + metrics + lineage") | `noetl/server` (lineage edges on registry entries) | G3 registry |
| **G6** | **Cost / quota controls.** Per-domain/tenant budget + quota on teacher tokens, GPU-job hours, and storage, with enforcement gates (a stage refuses to dispatch when over budget) and reporting. Generalizes "teacher budget" (travel open-decision 5) into an enforced platform control. | new (implied by travel §10 decision 5) | `noetl/server` (budget resource + gate) + `noetl/tools` (G1 dispatch checks quota) | G1/G3; keychain for credentials |

**Sequencing consequence (inherited from travel §6A.3):** the stages that run on **existing tool kinds** today — `dataset_build`, `eval`, `shadow_eval`, `traffic_capture`, `drift_monitor` (http + python + playbook + schedule + server-API) — are **not blocked** by G1–G6, so the floor/ceiling numbers and the capture→drift half of the loop can be built immediately. `finetune` + `package` are gated on G1/G2/G3; the registry/experiment/lineage/cost features (G3–G6) gate the *automated* loop's bookkeeping but can land in parallel with Phase A.

---

## 4. The continuous-improvement loop (the "constantly improved" core)

This is what turns "stand up a model once" into "tooling for organizations to **continuously improve** their SLMs". Every stage is a NoETL playbook; the loop is `slm/retrain_orchestrator` on a schedule composing them. Nothing here holds a worker slot for a long wait (G2 callback pattern) and nothing reads `noetl.*` directly (server API, data-access boundary).

```
                        ┌──────────────────────────────────────────────────────────┐
                        │              slm/retrain_orchestrator (cron)             │
                        └──────────────────────────────────────────────────────────┘
   live planner traffic         │
        │ (engine emits         ▼
        │  shadow/outcome  ┌───────────────┐   ┌───────────────┐   ┌────────────────────────┐
        └─────────────────►│ traffic_capture│──►│ drift_monitor │──►│ retrain TRIGGER? (§4.1)│
                           └───────────────┘   └───────────────┘   └───────────┬────────────┘
                                                                       no │     │ yes
                                                                          │     ▼
   ┌────────────────────────────────────────────────────────────────┐    │  ┌──────────────────────┐
   │  (teacher-assisted / human-in-the-loop) RELABEL captured turns  │◄───┼──┤ dataset_build (delta) │
   └────────────────────────────────────────────────────────────────┘    │  └──────────┬───────────┘
                                                                          │             ▼
                                          ┌──────────────┐   ┌────────────┴───┐   ┌──────────┐
                                          │ finetune     │──►│ eval (offline) │──►│ package  │
                                          │ (challenger) │   │  vs floor+incb │   └────┬─────┘
                                          └──────────────┘   └────────────────┘        ▼
                              ┌───────────────────────────┐   ┌──────────────────────────────────┐
   rollback (re-flip flag) ◄──┤ gated PROMOTE (§4.2)      │◄──┤ shadow_eval challenger vs incumbent│
                              │  registry version + deploy│   │  on live-shaped traffic            │
                              └───────────────────────────┘   └──────────────────────────────────┘
```

**Stage roles:**

1. **Production-traffic capture** (`slm/traffic_capture`) — sample live turns: inputs, the active engine's output, and outcome signals (user correction, retry, tool error, abandonment, downstream success). Redact PII per policy. Land in the dataset/experiment store via the server API. This is the labeled-data flywheel: real traffic + real outcomes.
2. **Quality / drift monitoring** (`slm/drift_monitor`) — on a schedule, score captured traffic: live match-rate vs the held-out eval, output-schema validity rate, outcome-signal regression (rising corrections/errors), and input-distribution drift (new intents/tools/cities the incumbent hasn't seen). Emits the drift signal G4 records.
3. **Teacher-assisted / human-in-the-loop relabeling** (`slm/dataset_build` delta mode) — re-label the captured turns the incumbent got wrong (high-disagreement, low-confidence, or negative-outcome) with the teacher + deterministic oracle; route teacher↔oracle disagreements (and a sampled audit slice) to human review. Append to the dataset as a new version (G3/G5 lineage).
4. **Scheduled retrain** (`slm/finetune`) — fine-tune a **challenger** on the new dataset version (warm-start from the incumbent adapter). Gated on §4.1 — drift/volume must justify the GPU spend (G6 budget check).
5. **Shadow-eval vs incumbent + deterministic floor** (`slm/eval` offline, then `slm/shadow_eval` live) — the challenger must beat the **deterministic floor** (never regress below the safe baseline) AND beat-or-match the **incumbent** on the held-out + golden-replay sets, then prove it on live-shaped shadow traffic (run alongside, log diff, discard output — zero user risk).
6. **Gated auto-promotion with registry versioning + instant rollback** (`slm/deploy`) — if §4.2 gates pass, register the challenger as the new serving release (G3 version + G5 lineage) and flip the engine flag. Rollback = re-flip the flag to the previous registry version — instant, because the incumbent release is still in the registry and (optionally) still deployed.

### 4.1 Retrain-trigger gates (what fires a retrain)

A retrain is **considered** on every schedule tick and **fired** when any trigger crosses threshold (all configurable per domain in `policies/retrain_gates.yaml`):

| Trigger | Signal (from G4/drift_monitor) | Default threshold |
|---|---|---|
| **Quality regression** | live match-rate vs held-out drops | > 2 pts below the promoted model's eval score |
| **Outcome regression** | rising user-correction / tool-error / abandonment rate on the active engine | > 1.5× the trailing-window baseline |
| **Schema-validity dip** | output-validity rate falls (grammar should hold this at ~100%; a dip means a contract drift) | < 99.5% |
| **Distribution drift** | share of turns hitting new/unseen intents, tools, or entities | > 5% of captured volume |
| **Data volume** | net-new high-confidence labeled turns since last train | ≥ N (domain-set, e.g. 2k) |
| **Contract change** | the I/O contract schema/vocab changed (new tool, new widget) | any change (force retrain) |
| **Cadence floor** | time since last successful retrain | ≥ max staleness (e.g. 30d), if budget allows |

The trigger gate also checks **G6 budget**: if the domain is over its GPU/teacher budget for the window, the retrain is deferred and an alert is emitted rather than silently skipped (observability.md: no silent caps).

### 4.2 Promotion gates (what gates an auto-promotion)

A challenger is auto-promoted **only if all** hard gates pass (configurable per domain in `policies/promotion_gates.yaml`); otherwise it stays registered-but-unpromoted and a human is notified:

| Gate | Condition | Why hard |
|---|---|---|
| **Floor** | challenger ≥ deterministic-oracle baseline on every metric | never ship something worse than the safe fallback |
| **Incumbent (offline)** | challenger ≥ incumbent on the primary metric set (held-out + golden-replay), no metric regresses > tolerance | don't replace a working model with a worse one |
| **Schema validity** | output-validity == 100% (grammar-enforced) on the eval set | invalid output degrades the user experience |
| **Shadow (live)** | live match-rate ≥ target AND latency p95 ≤ incumbent on shadow traffic | offline ≠ live; prove on real distribution |
| **Latency / cost** | serving p95 ≤ budget AND projected serving cost ≤ incumbent | a more accurate but slower/costlier model may not be a net win |
| **No-harm slice** | no protected/critical slice (per domain — e.g. booking-refusal correctness in travel) regresses | guard the cases where being wrong is expensive |

Promotion is **per-role** where the contract has multiple roles (flip `extract` to the challenger while keeping `render` on the incumbent), mirroring travel's per-pass cutover. Every promotion and rollback is an event (auditable, replayable); the registry keeps every version so rollback is a flag re-flip, not a rebuild.

---

## 5. Multi-tenancy / governance

The framework is multi-tenant by construction because NoETL already is. The additions are namespacing + enforcement.

- **Data isolation.** Each domain's capture/dataset/eval data is scoped `tenant=<org>/project=<domain>` and accessed only via the server API (data-access boundary — workers never touch `noetl.*` directly). The off-server CQRS + result-tier architecture (#104/#107) already addresses artifacts/lineage by **URN** (`noetl://<tenant>/<project>/results/…`); the registry (G3) reuses that URN scheme so a model/dataset/eval artifact is tenant-addressed and shard-resolved the same way a result is — isolation and shard-routing come for free.
- **Secrets.** Teacher API credentials, serving registry creds, any tenant data-source DSN live in the **keychain** referenced by alias (`{{ teacher_token }}`) — never in worker/gateway env (execution-model secrets rule). A local served SLM needs **no** business secret (and *removes* the teacher key from the hot path post-cutover).
- **Registry namespaces.** Model/dataset/eval/release entries are namespaced per `<org>/<domain>` (G3). One org cannot resolve or promote another org's models. Lineage (G5) edges stay within a namespace.
- **Cost controls.** Per-domain budgets/quotas (G6) on teacher tokens, GPU-job hours, storage — enforced at the dispatch gate, reported per domain.
- **Eval gates as policy.** The retrain/promotion gates (§4) are per-domain policy resources; an org owner sets the bar. Auto-promotion can be disabled per domain (require human approval) — the loop then stops at "challenger registered + human notified".
- **Audit.** Every lifecycle action (dataset version, train, eval, promote, rollback) is an event in the log (event-sourced, replayable) carrying `execution_id` (observability.md). "Why is this model in production and what was it trained on?" is a lineage query (G5), not an archaeology dig.

---

## 6. Packaging / distribution — how an org adopts this

The goal is **config-driven adoption**: an org installs a bundle, fills in `slm.config.yaml` + its schemas/prompts/seed-data, and runs. Two complementary shapes:

### 6.1 Templates (in-platform)

The `automation/mlops/slm/*` template pack ships with NoETL. An org adds a `automation/mlops/slm/<domain>/` directory with its config + contracts + prompts + data pointers and runs the templates. This is the minimum: no new distribution mechanism, just a documented template pack + the `slm.config.yaml` schema.

### 6.2 NoETL plugin / marketplace bundle (productized)

Package the framework as an installable **NoETL plugin** — mirroring the Cowork/Claude **plugin + marketplace** model (a plugin = playbooks + tools + a setup skill, discoverable from a marketplace, installed into a workspace):

- **Playbook pack** — the `slm/<stage>` templates + the `retrain_orchestrator`.
- **Platform tools** — the G1 container/GPU dispatch tool kind + the G3 registry resource kind (the runtime primitives the pack depends on).
- **A setup skill** — `slm-init <domain>` scaffolds the `<domain>/` directory from the config schema, validates the org's contract schemas, wires the consuming playbook's engine flags, and registers the schedule. (Analogous to the `setup-cowork` / `skill-creator` pattern: a guided, role-matched install.)
- **Marketplace listing** — discoverable, versioned, with the config schema as the contract. An org installs "the SLM MLOps plugin" the way a Cowork user installs a role plugin.

The plugin makes the platform foundations (G1/G3) a **dependency** the bundle declares, so installing the plugin pulls in the runtime primitives. This is the "tooling for organizations" surface: adoption is *install plugin → run setup skill → fill config*, not *write a pipeline*.

> Productization scope (internal capability vs external marketplace product, self-hosted vs managed) is **open decision 1** (§10) — the architecture supports either; only the distribution/billing wrapper differs.

---

## 7. Relationship to travel (the reference implementation)

Travel#63 is **not** a sub-project of this umbrella to be built later — it is the **already-in-flight worked example** that proves the framework end-to-end. The relationship is extraction, not duplication:

- The generic `slm/<stage>` templates (§2) are **extracted from** travel's `travel-slm/<stage>` playbooks. Travel is `slm.config.yaml` instance #1.
- The platform foundations G1/G2/G3 (§3) are the **generalization of** travel#70/#71/#72 — same gap, promoted from travel-scoped to platform-scoped. Travel's issues become the **seeds**; the platform issues are where the domain-agnostic feature lands; travel consumes the generalized feature.
- Travel's contract (§2 of the travel RFC — the extract/render I/O spec, the tool catalog, the widget union, the eval metrics) is the **first filled-in config surface**; it validates that the §2.2 config schema is expressive enough for a real domain.
- Travel's phased rollout (Phase 0–5, the per-stage playbooks, the engine flags, the shadow→cutover) **is** Phase A of this umbrella (§8): "prove it on travel using the generic templates".

Concretely: travel proves it; we extract the framework from what proved out; the second domain validates the extraction by running unchanged templates. Travel's issues + wiki get a note that they are the reference implementation of this platform umbrella (no scope change to travel).

---

## 8. Phased plan

Each phase ships as NoETL playbooks/tools + tracking, honoring the platform rules (kind-validate before GKE; observability artifacts per change; data-access via server API; secrets in keychain). **No training/infra/prod change is performed by this RFC** — phases below are the plan, not actions taken.

### Phase A — Prove it on travel using the generic templates *(child issue A)*

Run the travel SLM lifecycle (travel#63 Phases 1–5) on the **generic `slm/<stage>` templates instantiated by travel's `slm.config.yaml`**, rather than travel-only playbooks. The not-gated stages (`dataset_build`, `eval`, `shadow_eval`, `traffic_capture`, `drift_monitor`) run on existing tool kinds; `finetune`/`package` wait on G1–G3 (Phase B).

- **Success:** travel's floor (deterministic) + ceiling (teacher) + a no-fine-tune baseline are produced **by the generic templates + travel config**; the config schema (§2.2) is proven expressive on a real domain; the shadow/cutover flags work through the generic `deploy` stage.

### Phase B — Extract + parameterize the template pack + platform foundations *(child issues B, G1, G2, G3)*

Extract the seven travel stages into `automation/mlops/slm/*` templates driven by `slm.config.yaml`; land the generalized platform foundations.

- **G1** container/GPU k8s-Job dispatch tool kind; **G2** long-running async job orchestration; **G3** large-artifact storage + versioned model/dataset/eval registry on the #104 result tier.
- **Success:** travel's `finetune` + `package` run on the generic templates + G1–G3 (un-gated end-to-end on kind); a **second toy domain** (a deliberately different, minimal contract) stands up dataset+eval **by config only**, zero framework-playbook edits — the extraction test.

### Phase C — Continuous-improvement loop + registry/experiment/lineage *(child issues C, registry/G4, loop)*

Land `slm/traffic_capture` + `slm/drift_monitor` + `slm/retrain_orchestrator`, the retrain/promotion gates (§4), and G4 experiment store + G5 lineage + G6 cost controls.

- **Success:** on a schedule, captured travel traffic drives a drift check → conditional retrain → eval → shadow → **gated** promotion with a registry version + instant rollback, **end-to-end on kind**, with every retrain/promotion gate (§4.1/§4.2) evaluated and auditable; over-budget defers (not silently skips).

### Phase D — Packaging / plugin for external orgs *(child issue D)*

Package the framework as a NoETL plugin/marketplace bundle (§6) + the `slm-init` setup skill + the published `slm.config.yaml` schema + adoption docs.

- **Success:** an org outside travel installs the bundle, runs `slm-init <domain>`, fills config, and reaches a first eval baseline **without touching framework internals**; the plugin declares G1/G3 as runtime dependencies; docs cover the full config surface.

---

## 9. Tracking

- **Umbrella:** noetl/ai-meta#139 — "Domain-Specific SLM platform — build + continuously improve org SLMs via NoETL playbooks" — labels `slm`, `ml`, `platform`, `epic`, `rfc`, `ai-task`.
- **Phase children:** #140 Phase A (prove-on-travel via generic templates), #141 Phase B (extract template pack + G1/G2/G3), #142 Phase C (continuous-improvement loop + registry/experiment/lineage), #143 Phase D (packaging/plugin).
- **Platform-foundation children:** #144 G1 (container/GPU job dispatch tool — generalizes travel#70), #145 G2 (long-async job orchestration — generalizes travel#71), #146 G3 (artifact storage + model/dataset/eval registry — generalizes travel#72, built on #104), #147 G4 (experiment/eval-metrics store), #148 G5 (model lineage/provenance), #149 G6 (cost/quota controls), and #150 the continuous-improvement-loop engine.
- **Reference implementation:** noetl/travel#63 (+ phase children #64–#68, capability-gap seeds #70/#71/#72) — the worked example; gets a "reference implementation of noetl/ai-meta#139" note.
- **Built on:** noetl/ai-meta#104 (result tier — G3's blob substrate), noetl/ai-meta#107 (distributed-OS program — execution substrate).
- **Wiki:** [Umbrella — Domain-Specific SLM Platform](https://github.com/noetl/ai-meta/wiki/Umbrella-Domain-SLM-Platform); the board (roadmap-boards.md) gets the umbrella + children.

---

## 10. Open decisions for the platform owner

1. **Internal capability vs external product/marketplace offering.** Is this an internal NoETL capability (we use it for travel + future first-party domains) or a packaged marketplace plugin sold/distributed to external orgs? Affects Phase D scope, the billing/quota surface (G6), and the support contract. *(RFC builds the architecture either way; only the distribution wrapper differs.)*
2. **Self-hosted-only vs managed.** Do orgs run the whole lifecycle on their own cluster (self-hosted) or do we offer a managed control plane (we run train/registry, they bring data + contract)? Affects multi-tenancy isolation depth (§5) and the GPU-pool ownership.
3. **Base-model families to support.** Pin a supported set (e.g. Qwen2.5, Llama-3.2, Phi-3.5, SmolLM2) or keep `base_family` open per domain? A supported set simplifies the `finetune`/`package` recipes + serving images; open maximizes flexibility but multiplies test surface.
4. **Build vs buy for the registry + experiment tracking (G3/G4/G5).** Build the model/dataset/eval registry + experiment store as native NoETL catalog resource kinds (on #104), or integrate an existing stack (MLflow / Weights & Biases / DVC / a model registry) behind the same playbook interface? Native keeps it dogfooded + URN-addressed + tenant-isolated; integrate is faster but adds an external dependency to the data-access boundary.
5. **Human-in-the-loop labeling scope.** How much human review in the relabel stage (§4 step 3)? Options: teacher+oracle only (fully automated, humans audit a sample), human-reviews-disagreements (teacher↔oracle conflicts go to a queue), or human-approves-every-promotion (auto-promotion disabled by default). Sets the default `governance` posture.
6. **Teacher model policy.** Which teacher(s) are sanctioned as labeling oracles (Claude / OpenAI / Vertex / an in-house large model), and the per-domain token budget (G6)? Also: is a frontier API acceptable as a *teacher* even when the *goal* is removing a frontier API from the hot path? *(RFC: yes — teacher spend is one-time/amortized, hot-path spend is per-request.)*
7. **Auto-promotion default.** Ship gated **auto**-promotion on by default (§4.2 gates gate it) or default to "challenger registered + human approves the flip"? Aggressiveness vs safety; per-domain overridable.
8. **GPU pool ownership + serving target default.** Provision a shared GPU node pool for `finetune`/`package` (and GPU serving), or CPU-only serving (llama.cpp/Ollama) with train jobs on ephemeral/spot GPU? Ties to decisions 2 + travel open-decisions 2/7. CPU-only serving removes a standing GPU cost; GPU serving buys lower latency.
