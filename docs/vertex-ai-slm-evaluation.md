# Evaluation: Vertex AI for our small language models, across four domains

- **Status:** evaluation only — no prod change proposed beyond a gated pilot.
- **Date:** 2026-09-23
- **Scope:** noetl internal (SLM context / stepgen), travel (muno), drug design
  (GLUT KB), quantum cloud (saqbit / IonQ).
- **Method:** every architectural claim below is marked **VERIFIED** (checked
  against this tree or the live prod control plane on 2026-09-23) or
  **ASSUMED / UNVERIFIED (external)**. Vendor pricing is third-party unless
  marked otherwise — Google's own pricing page did not render usable content
  through the fetch tool, so the rates here come from aggregators and are
  labelled as such.

---

## 0. Bottom line

Three findings change the question that was asked.

1. **The pluggable model-backend already exists and is already in production.**
   The evaluation asked whether Vertex could be "a plug behind an OpenAI-shaped
   abstraction". It already is: `resolve_triage_backend` selects between
   `mcp/ollama`, `mcp/vertex-ai-stub` and `mcp/vertex-ai` from a workload knob,
   and travel's planner runs `ai_provider: vertex-ai` in the **registered**
   catalog today. There is nothing to build for deliverable 3 — only gaps to close.

2. **The cost direction in the brief inverts below a crossover we are nowhere
   near.** A dedicated Vertex endpoint bills by the **GPU-hour**, not per token.
   Per-token Gemini is cheaper than any dedicated endpoint until roughly
   **300M tokens/day**; our whole platform is on the order of **single-digit
   millions**. At our volume, managed per-token is the *cheap* option by about
   two orders of magnitude. Self-hosting is justified by **residency and
   offline**, not by cost.

3. **Both live model pins retire in 23 days.** `gemini-2.5-flash` is pinned in
   `muno/playbooks/itinerary-planner` v114 and `automation/agents/mcp/vertex-ai`
   v13. Multiple sources put Gemini 2.5 retirement at **2026-10-16**. This is an
   operational finding that outranks the evaluation itself.

---

## 1. Grounding — verified against the tree and live prod

| Claim | Status | Evidence |
| :-- | :-- | :-- |
| Model calls go through `tool.kind: mcp`, model chosen at runtime | **VERIFIED** | `repos/ops/.../troubleshoot/diagnose_execution.yaml:301,306` — `model: "{{ resolve_triage_backend.model }}"` |
| Backend selector exists (ollama / vertex-stub / vertex) | **VERIFIED** | same file `:236-295` — `resolve_triage_backend` returns `{server,endpoint,tool,model,source_hint}` |
| `gemma3:4b` ops pin | **VERIFIED** | same file `:75` (`triage_model`) and `:239` (`DEFAULT_MODEL`); also `helm/noetl/values.yaml:580` |
| A real Vertex MCP backend is implemented, not a stub | **VERIFIED** | `repos/ops/automation/agents/mcp/vertex-ai.yaml` — "PRODUCTION IMPLEMENTATION", same `chat_completion` contract as `mcp/ollama` |
| Travel already runs on Vertex **in the registered catalog** | **VERIFIED** | `muno/playbooks/itinerary-planner` **v114**, registered 2026-09-15: `ai_provider='vertex-ai'`, `llm_extraction_model='gemini-2.5-flash'`, `vertex_region='us-central1'` |
| Vertex calls run against the **retired** project | **VERIFIED** | same payload: `vertex_project='noetl-demo-19700101'`, not `shastaratech-noetl-prod` |
| S6 treats model choice as a pointer swap | **VERIFIED** | `specs/active/2026-09-19-slm-ehdb-context/S6-gemma4-serving.md` — "Gemma 4 is a pointer swap, not a code change" |
| `model_ref` fork | **VERIFIED (as spec)** | S6: `ModelRef { family, variant, digest, server, api }`; flag `NOETL_SLM_MODEL_REF`, default unset. Planning only — not implemented. |
| Signal-mesh runs a deterministic reasoner; real model is later | **VERIFIED (as spec)** | `repos/signal-mesh/docs/spec/a2a-react-signal-mesh.md` — SLM stepgen in **PROPOSE** mode, "validate and count; never execute (§8)" |
| **No self-hosted inference exists in prod** | **VERIFIED** | prod has **3 nodes, 0 GPU nodes**; no `ollama`/`vllm` Deployment, StatefulSet or Service in any namespace |
| GLUT scientific/tenant context is barred from ai-meta | **VERIFIED** | `memory/archive/2026/05/20260522-033157-glut-memory-ownership-rule.md`; `agents/rules/allowed-content.md` |
| Every **Gemma 4** product fact (sizes, variants, native function calling) | **UNVERIFIED (external)** | S6 marks these unverified; this evaluation does not re-verify them |

### The reachability finding

`mcp/ollama` is the **default** triage backend (`DEFAULT_SERVER = "mcp/ollama"`,
`diagnose_execution.yaml:238`) and points at
`ollama-bridge.noetl.svc.cluster.local:8765`. **That Service does not exist in
prod.** The default path is configured and unreachable — the house failure mode
(`agents/rules/representation-drift.md`: existence and reachability are
independent questions). Anything that falls back to the default today fails.

This also means "move to self-hosted" is **not** a return to something we run.
It is a greenfield GPU build.

---

## 2. Comparison matrix

The brief framed this as two options. There are **three**, and conflating the
middle one with the first is what produces the wrong cost conclusion.

| | **A. Per-token API** (Gemini on Vertex) | **B. Managed dedicated endpoint** (Gemma via Model Garden) | **C. Self-hosted** (Ollama / vLLM on our GKE) |
| :-- | :-- | :-- | :-- |
| Billing unit | per token | **per GPU-hour** while ≥1 replica runs, + mgmt fee + small per-1K-request fee | node cost (our GKE) + ops |
| Indicative rate | Gemini 2.5 Flash **$0.10/1M in, $0.40/1M out**; 2.5 Pro $1.25–2.50/1M in, $10–15/1M out *(cloudzero, third-party)* | A100 40GB ≈ **$2.93/hr + ~$0.44/hr mgmt ≈ $3.37/hr**; H100 80GB ≈ $9.80 + $1.47 ≈ **$11.27/hr** *(third-party, us-central1)* | GPU node price + engineer time; **we currently have no GPU node** |
| Idle cost | **zero** | **full hourly rate** — pays while idle | full node rate unless scaled down |
| Scale-to-zero | n/a (no endpoint) | not assumed — treat as **ASSUMED** absent verification | possible, with cold-start cost |
| Latency | network + model; no cold start | no cold start once warm | lowest in-cluster, but cold start on scale-up |
| Ops burden | ~none | low (Google runs the node) | **high** — GPU nodes, drivers, model store PVC, upgrades, HA |
| Autoscaling | implicit | `max_replica_count` on the endpoint | KEDA/HPA, ours to build |
| Function calling | strong on Gemini (**ASSUMED**, not re-verified here) | Gemma native FC is **UNVERIFIED (external)** per S6 | whatever the served model supports |
| Data residency | in-region **in Google's tenancy**; weights + inference outside our control | same | **in our cluster** — the only option that keeps inference under our control |
| Model choice | Gemini family only | open weights incl. Gemma sizes | anything we can serve |

### Cost model and the crossover, with the arithmetic shown

Dedicated endpoint, one replica, 24/7, A100 40GB:

```
$3.37/hr × 24 × 30  ≈  $2,426 / month  ≈  $29,000 / year   (per replica)
```

Per-token Gemini 2.5 Flash, blended 1:1 input:output:

```
($0.10 + $0.40) / 2  =  $0.25 per 1M tokens
```

Crossover — the volume at which the dedicated endpoint stops being more
expensive than per-token:

```
$2,426 / $0.25 per 1M  ≈  9,700M tokens/month  ≈  ~320M tokens/day
```

**Our actual volume is nowhere near that.** Over a verified ~28-hour window
(2026-09-22T11:20 → 2026-09-23T15:10) the prod control plane recorded **100
executions** — and that 100 is the API's page cap, so it is a **floor, not a
count**. Even on a generous assumption of 10 model calls per execution at 3K
tokens each, that is ~2.6M tokens/day: **roughly 100× below the crossover**.

> **Correction to the brief.** The figures supplied (`~$0.13/1K input,
> $0.52/1K output`) are ~1000× the published Gemma-class per-token rates and
> appear to be a per-1M figure labelled per-1K. More importantly, the
> Gemma-on-Vertex path is **hourly, not per-token** at all, so a per-token
> comparison for Gemma is category-wrong. The brief's stated direction —
> "managed = costly, self-hosted = cheap at scale" — is correct *only above the
> crossover*, and we are two orders of magnitude below it. Below the crossover
> the ordering reverses: **managed per-token is the cheap option.**

The "GKE H100 24/7 HA ≈ six figures/yr" figure in the brief is directionally
consistent with the table above (2 × H100 replicas ≈ $197k/yr at the quoted
hourly rate) and is an argument **against** self-hosting at our volume, not for it.

---

## 3. Per-domain recommendations

### 3.1 noetl internal (SLM context / stepgen) — **stay self-host-*intent*, but fix the default first**

The brief expects "high-volume → self-hosted at scale, Vertex to start". At
current volume the cost argument for self-hosting does not hold, and the
self-hosted arm **does not exist** (0 GPU nodes; the `ollama-bridge` Service the
default points at is absent).

- **Now:** repair the reachability gap. Either stand up the Ollama bridge or
  change `DEFAULT_SERVER` so the default path is one that resolves. A
  configured-but-unreachable default is the defect class this program keeps
  finding.
- **Then:** point internal triage at Vertex behind the existing knob — it is a
  workload-field change, not a code change.
- **Revisit self-hosting when** sustained usage approaches ~300M tokens/day, or
  when an offline/air-gapped requirement appears. S6's preference for local
  serving is sound on *latency, offline and data locality* grounds; it should
  not be defended on cost at today's volume.

### 3.2 travel (muno) — **already on Vertex; the live decision is the model pin, not the platform**

Travel is not a candidate — it shipped. `itinerary-planner` v114 runs
`ai_provider: vertex-ai` with `gemini-2.5-flash`. The open items are:

- **Urgent:** `gemini-2.5-flash` retires **2026-10-16** (23 days). Pick the
  successor and re-pin. This is user-facing.
- **Governance:** `vertex_project = noetl-demo-19700101` — the retired project.
  Production user traffic is being served through it. This is the same
  incomplete-severance pattern recorded in memory, now on the LLM hot path.
- Latency and cost are fine on per-token Flash at this volume; no reason to move.

### 3.3 drug design (GLUT KB) — **self-hosted, and the burden of proof is on anything else**

This is the one domain where the cost analysis is not the deciding input.

- Our own governance already bars GLUT scientific/tenant context from ai-meta
  (**VERIFIED** rule). A domain whose *memory* is too sensitive for our own
  public repo should not have its *inference* sent to a managed endpoint by
  default.
- Both managed options put weights and inference in Google's tenancy. Only
  option C keeps inference inside our cluster.
- **Recommendation:** do not route GLUT through Vertex. If a model is needed
  before we have GPU capacity, gate it behind an explicit, documented decision
  by the data owner — not behind the same flag the other domains use.
- The FRIA / DPIA-style questions below are live for this domain specifically.

### 3.4 quantum cloud (saqbit / IonQ) — **the brief's premise is wrong; it is our heaviest workload**

The brief describes saqbit as "light, demo → convenience". In the verified
28-hour window, **`saqbit/playbooks/qaoa-maxcut` was the single most-executed
path in prod — 55 of 100 sampled executions**, more than twice `system/scheduled_cleanup`.

Two honest qualifications: that 100 is a page cap (so proportions are from a
sample, not a census), and **I did not verify that the saqbit playbook makes any
model call at all** — its source is not in this tree and I did not fetch its
registered payload. High execution volume is not the same as high token volume.

- **Recommendation:** before choosing a backend, answer the prior question —
  *does saqbit call a model, and at what token volume?* If it does, it is the
  domain most likely to approach a crossover, and it is being sized on an
  assumption that the execution data contradicts.
- If it does not call a model, it is out of scope for this evaluation entirely.

---

## 4. The pluggable model-backend — it exists; here is the gap

`resolve_triage_backend` (`diagnose_execution.yaml:236-295`) already is the
abstraction:

- one `chat_completion` contract implemented by `mcp/ollama`, `mcp/vertex-ai`
  and `mcp/vertex-ai-stub`;
- selection by workload knob (`triage_mcp_server`, `triage_model`), with
  per-server endpoint defaults;
- `source_hint` recorded on the result, so the answer carries **which backend
  answered** — the property S6's `model_ref` extends.

Three gaps worth closing, none of them a new abstraction:

1. **The default does not resolve** (§1). Fix before anything else.
2. **Selection is per-playbook, not per-domain.** Each caller carries its own
   knob; there is no one place to say "GLUT never uses a managed backend".
   A domain-level policy — a deny-list a playbook cannot override — is what the
   sensitive domain actually needs, and it does not exist today.
3. **`model_ref` is spec-only.** Until it lands, the record of what answered is
   a *name*, not a pin. S6 already warns that storing a name in a field called
   `digest` would be exactly the drift this program keeps finding.

---

## 5. Pilot — one model call, behind a flag, nothing user-facing

Deliberately smaller than the brief proposed, because the integration already
exists: the pilot is a **pointer swap plus a measurement**, not a deployment.

**Target:** `automation/agents/troubleshoot/diagnose_execution` — internal
triage, propose-mode by construction, nothing user-facing.

**Change:** set `triage_mcp_server: mcp/vertex-ai` and
`triage_model: gemini-2.5-flash-<successor>` on that playbook's workload only.
No code change, no new endpoint, no GPU spend, no commitment.

**Acceptance check** — all four must hold:

1. A triage execution completes with `resolve_triage_backend.source_hint ==
   "vertex-ai"` — i.e. the Vertex path was *actually taken*, not merely
   configured. (Guard against the false-clean: a run that silently fell back to
   the default must fail the check, so assert the hint, not just success.)
2. The classification result is non-empty and parses into the same shape
   `mcp/ollama` returns — contract parity, not answer quality.
3. Observed p50/p95 latency recorded for at least 20 calls, alongside the
   token counts the response reports.
4. Cost for the pilot window computed from those token counts at the published
   per-token rate, and compared against the §2 crossover.

**Rollback:** revert the two workload fields. One catalog re-register.

**Explicitly out of scope:** deploying Gemma to a Model Garden endpoint. At our
volume that starts a ~$2.4k/month meter to answer a question the per-token path
answers for cents.

---

## 6. Risks and open questions

**Risks**

- **Model retirement is the live risk, not cost.** Two prod pins expire
  2026-10-16. A managed per-token API means Google's retirement calendar is on
  our critical path; self-hosting trades that for an upgrade burden we own.
- **Retired-project dependency.** Production LLM traffic runs through
  `noetl-demo-19700101`. Any cleanup of that project is now a user-facing
  outage risk.
- **Cost at scale is real but distant** — it begins to bind near ~300M
  tokens/day, and nothing here suggests we are approaching it.
- **A dedicated endpoint bills while idle.** For bursty workloads (ours are
  bursty) that is the worst-fitting billing shape of the three.
- **Function-calling parity is unverified** in both directions — Gemma's native
  support is external and unchecked (S6), and I did not re-verify Gemini's.

**Open questions**

1. Does `saqbit/playbooks/qaoa-maxcut` make model calls, and at what token
   volume? This is the largest single unknown and it decides §3.4.
2. Which model replaces `gemini-2.5-flash` before 2026-10-16, and who owns the
   re-pin?
3. Should Vertex calls move to `shastaratech-noetl-prod`, and what breaks if
   they do?
4. Does Model Garden's dedicated endpoint support scale-to-zero? If yes, option
   B's economics change materially and this matrix should be redone.
5. For GLUT: what is the actual regulatory frame — is a managed endpoint
   categorically excluded, or permitted under a DPIA/FRIA-style assessment with
   a data-processing agreement? Vertex leaves that assessment to us.
6. Do we want a domain-level policy layer (§4.2) that a playbook cannot
   override, before any sensitive domain gets a model call?

---

## Sources

Third-party pricing aggregators — Google's own pricing page did not render
usable content through the fetch tool, so **none of the rates below are
first-party** and all should be confirmed against the Google Cloud console
before any spend commitment.

- [Google Vertex AI pricing in 2026 — CloudZero](https://www.cloudzero.com/blog/google-vertex-ai-pricing/)
- [Vertex AI Model Garden Pricing 2026: Cost vs Self-Hosted — Spheron](https://www.spheron.network/blog/vertex-ai-model-garden-pricing-2026-cost-vs-self-hosted/)
- [Vertex AI Pricing: The Complete 2026 Guide — nOps](https://www.nops.io/blog/vertex-ai-pricing/)
- [Deploy and inference Gemma using Model Garden — Google Cloud docs](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-garden/deploy-and-inference-tutorial)
- [Overview of self-deployed models — Google Cloud docs](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-garden/self-deployed-models)
- [Generative AI on Vertex AI deprecations — Google Cloud docs](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/deprecations)
- [Gemini deprecations — Google AI for Developers](https://ai.google.dev/gemini-api/docs/deprecations)
- [Gemini 2.5 Pro and Flash Retirement: October 16, 2026 — benchr](https://benchr.org/deprecations/gemini-2-5-pro)
