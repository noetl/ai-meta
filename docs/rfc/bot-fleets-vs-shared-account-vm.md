# RFC: bot fleets on NoETL vs one shared VM per account — an honest comparison, and what to build to win

Status: **analysis + proposed architecture. Nothing in §7 is built.** This document only describes and recommends; it
changes no code and touches nothing in prod.
Written 2026-11-13 against `main` of server `983e36e`, worker `d1c9584` (v6.15.0), tools `c2e75ee` (v4.6.0), and the
published resource model `https://noetl.ai/dsl/resource-model.json` (`as_of` 2026-11-11, `model_version` 1).

Owner framing: *"If we don't have winning arguments we need to adjust architecture to make it a true win."* So this is
not a pitch. §5 lists where NoETL loses today, and §7 says what has to change for the claims in §2 to be true.

Related:
- [`coroutines.md`](coroutines.md) (ai-meta#554): structured concurrency, cancellation and backpressure. Accepted,
  nothing built.
- [`distributed-playbook-catalog.md`](distributed-playbook-catalog.md) (ai-meta#548): content-addressed catalog,
  execution pinning, compiled-playbook WASM, cross-instance delegate.
- [`interop-missing-tools-build-plan.md`](interop-missing-tools-build-plan.md) (ai-meta#544): agents on shared pools,
  item 8.
- [`secret-manager-retrieval.md`](secret-manager-retrieval.md) (the Secrets Wallet, ai-meta#61).
- [`g1-g2-container-job-async.md`](g1-g2-container-job-async.md) (`kind: container` as a Kubernetes Job).

**Labels.** Every claim carries one:
- **REAL**: in the code today, cited.
- **DEPLOYED**: read off prod, via the resource model.
- **MEASURED**: observed, with date and environment.
- **DEFAULT**: a code default that a deployment may override.
- **GIVEN**: the competitor model as the owner stated it; not independently verified.
- **TARGET**: proposed here.
- **NOT_YET_MEASURED**: a real question with no number. None is invented.

---

## 0. Executive summary

**The competitor (GIVEN).**
- Each user account gets one always-on Firecracker microVM: ~8 vCPU, ~16 GB RAM (ballooned down under pressure),
  128 GB disk, Debian 13.
- All of the account's bots share that machine's files, browser sessions, credentials, CPU, RAM and disk.
- The isolation boundary is the user, not the bot.

**Where NoETL genuinely wins today**
1. **Idle bots cost nothing per account.** A NoETL bot at rest is a catalog row and an event history. Compute is a
   shared, elastic pool sized to concurrent *work*, not to the number of accounts.
   - The whole prod user pool's floor is **2 replicas × 250m CPU / 256Mi request** (DEPLOYED). That is about a
     sixteenth of the CPU one competitor account holds idle.
   - It scales to **20 replicas / 80 slots** on command-bus lag (DEPLOYED). The 2 → 20 → 2 ramp was observed under
     200 real executions (MEASURED, prod, 2026-07-31).
2. **Fan-out beyond one machine.** One execution fans steps out across every replica of a pool, and a fleet's runs
   spread across all pools. The competitor's account is capped at its one VM and one computer-use task per screen
   (GIVEN).
3. **Every run is a durable, attributable record.** Each step emits lifecycle events to an append-only log. Each agent
   turn and tool call is an event (`agent.turn`, `agent.tool_call`, `agent.final`), and token usage is in `call.done`
   (REAL). Playbooks have content digests, and an execution can be pinned to one version for its whole life, across
   instances (REAL in v3.157.0–v3.161.0, **off on prod**). A shared mutable VM offers none of this by construction.

**Where NoETL does not win today; said plainly in §5**
1. **Isolation in the cluster runtime is weaker than the competitor's.** Most step kinds run inside a shared,
   multi-tenant worker process. `python` and `shell` run as subprocesses that **inherit the worker's whole
   environment**, uid, pod filesystem and network (REAL, `tools/src/tools/python.rs:637-646`; there is no
   `env_clear`). Named credentials resolve by name for any caller. The internal auth gate is in shadow mode on prod.
   - The competitor isolates *users* from each other with hardware virtualisation.
   - NoETL's worker pools serve *every* user's steps in the same pods.
   - Today NoETL does **not** give each bot a security boundary, and does not even match per-user VM isolation.
2. **Single-task latency is worse.** Orchestration cost **~4.5 s per step** and **~9–15 s per sub-playbook hop**,
   and was **~82 % of a planner turn** (MEASURED, prod, 2026-08). The latest measurement is **~0.95 s per step**
   (prod, 2026-11-02). §7.0 attributes it: mostly two dispatches per step, the claim round trip and 2 s polling on
   hops; raw Postgres is ~10–15 %. A bot doing one interactive, latency-sensitive
   thing on a warm VM will finish first.
3. **No desktop, browser or persistent workspace.** There is no `kind: browser`, no screen, no sudo, and no persistent
   per-bot disk. For long-lived interactive dev or browser work, the competitor's model is simply the right shape.
4. **Two "elastic" claims are not true yet.** The pools are **not scale-to-zero** (KEDA min 2; the system pool is
   fixed at 1 + 1 with no autoscaler). There is **no backpressure**: `loop.spec.max_in_flight` is parsed and has no
   reader.

**What to build so the win is real (§7, top three)**
1. **A per-bot sandbox and a credential capability model.**
   - Every untrusted or agent step runs in either a capability-scoped WASM sandbox or a per-execution sandbox pod
     (gVisor or Kata RuntimeClass, cleared env, no service-account token, default-deny egress).
   - Credentials are bound to (bot identity, playbook digest), short-lived, and sealed per command rather than per
     worker.
   - The auth gate is enforced.
   - This makes "each bot is its own boundary with only its own credentials" true. It is strictly stronger than
     bots sharing everything inside one account VM.
2. **Collapse orchestration overhead.**
   - Run deterministic step chains and pure sub-playbooks inside one command, in-worker or at the edge as compiled
     WASM, instead of one dispatch, claim and three emits per step.
   - Remove the per-process WASM mutex.
   - Target: fused steps under 100 ms of orchestration each (TARGET, to be measured), so per-step overhead stops
     deciding the latency of a bot turn.
3. **True elasticity: scale-to-zero plus structured backpressure.**
   - Scale agent pools to zero, with a pre-compiled WASM warm tier.
   - Implement coroutines stage 1 with enforced `max_in_flight` and per-tenant quotas.
   - Stop holding a worker slot while waiting on an LLM or a child.
   - Give stateful desktop or browser bots an on-demand, snapshot-and-suspend sandbox **per bot session**, billed
     only while active, instead of an always-on VM per account.

---

## 1. The two models

### 1.1 Shared VM per account (GIVEN)

| Property | Value |
|---|---|
| Unit of compute | one Firecracker microVM per **user account** |
| Size | ~8 vCPU, ~16 GB RAM (memory ballooning reduces it under host pressure), 128 GB disk, Debian 13 |
| Boot | Firecracker boots in < 125 ms, but the guest is a large, always-on instance, not a per-task microVM |
| Inside an account | all bots share files, browser sessions, credentials, CPU, RAM and disk; bots are not a security boundary |
| Between accounts | hardware-virtualised isolation |
| Desktop | a screen per bot, one computer-use task per screen at a time; all screens compete for the same 8 cores and 16 GB |
| Under contention | concurrent browser automation, big builds or memory-heavy processes contend; free RAM can fall to low single-digit GB |

### 1.2 NoETL (REAL unless labelled)

| Property | Value |
|---|---|
| Unit of work | a **step** (one command) inside an **execution** of a content-addressed playbook |
| Unit of compute | a worker slot: `WORKER_MAX_CONCURRENT`, DEFAULT 4 per process (`worker/src/config.rs:115-118`). A pool's capacity is replicas × slots; excess commands queue on the command bus. |
| User pool (DEPLOYED) | `noetl-worker-rust`: 250m CPU request / 2 limit, 256Mi request / 768Mi limit per replica; KEDA 2–20 on `ehdb_feed_subject_lag` (target 2, poll 10 s, cooldown 30 s); 8 slots at min, 80 at max |
| System pool (DEPLOYED) | `noetl-worker-system-pool` + `-shard1`: 750m request / 2 limit, 3Gi / 3Gi, 1 + 1 replicas fixed, 2 slots each (4 total). A ScaledObject (3–10) exists in `ops/ci/manifests` but is not on the cluster. |
| Routing | a worker claims only its pool's subject (`commands.<pool>.>`); a step goes to the pool its command is published to (`worker/src/worker.rs:233-244`) |
| Step execution | per kind, from the resource model's `step_kinds`: `http`, `postgres`, `duckdb`, `rhai`, `agent` and `mcp` run **in the worker process**; `python` and `shell` run as **subprocesses in the worker pod**; `wasm` runs **in-process under wasmtime**, one module at a time per process; `container` is a **separate Kubernetes Job** (`tools/src/tools/container.rs`); `playbook` starts a **child execution** |
| Edge | a pure playbook compiles to a WASM module whose digest equals the catalog digest (`plugins/playbook-wasm`, ai-meta#548 phase 3), and it can run outside the cluster, for example in a Cloudflare Worker (§2.5) |

---

## 2. Point-by-point comparison

| Dimension | Shared VM per account (GIVEN) | NoETL today | NoETL after §7 (TARGET) | Verdict today |
|---|---|---|---|---|
| Boundary between users | hardware VM | shared worker pods for every user (REAL) | per-execution sandbox pod or WASM capability sandbox | **competitor wins** |
| Boundary between bots of one user | none | none for in-process and subprocess kinds; real for `container` (a separate pod) and `wasm` (fuel, memory, no ambient I/O in pure modules) | every bot step in its own sandbox | tie (both weak); NoETL has the building blocks |
| Credentials | all bots see all of the account's credentials | playbook-declared keychain entries are execution-scoped (REAL); global named credentials resolve for any caller (REAL); delivery can be sealed to a worker key (REAL); subprocesses inherit worker env (REAL) | credentials bound to (bot, digest), short-lived, sealed per command, enforced auth gate | competitor slightly worse inside an account; NoETL worse across users |
| Idle cost per account | one ~8 vCPU / 16 GB VM | ~0 per account: a catalog row plus history | ~0, and pools at zero when the fleet is idle | **NoETL wins** |
| Platform floor | n/a (per account) | user pool 0.5 vCPU / 512Mi requested; system pool 1.5 vCPU / 6Gi (DEPLOYED). Server, writer and Postgres are not in the model. | user and agent pools at 0; system pool scaled | NoETL wins once there are more than a handful of accounts |
| Burst capacity of one fleet | 8 vCPU, one machine | 80 slots across 20 pods (DEPLOYED max); a new node takes ~60–90 s (MEASURED, prod) | the same, plus enforced quotas and fair share | **NoETL wins** |
| Concurrency control | the OS scheduler; one computer-use task per screen | fan-out and fan-in are REAL; no throttle (`max_in_flight` has no reader); an awaited child or agent tool holds the parent's slot | spawn / join / race with enforced limits (coroutines RFC) | NoETL wins on scale, loses on control |
| Single-task latency | local process, no orchestration hop | ~4.5 s/step, ~9–15 s/hop (MEASURED, prod 2026-08); prod turns 17.0–21.2 s planner, 6.4–7.0 s concierge (MEASURED, 2026-11-04) | fused segments, under 100 ms/step orchestration | **competitor wins** |
| Cold start | < 125 ms boot (GIVEN), but the VM is usually already up | ~138 ms issue → claim on an unsaturated pool (MEASURED, prod 2026-07-30); WASM first dispatch ~1.5 s, then cached (MEASURED, kind) | WASM pre-compiled at boot; edge WASM | roughly even |
| Desktop, browser, sudo, persistent disk | yes | none | an on-demand per-session sandbox with snapshot and suspend | **competitor wins** |
| Reproducibility | mutable shared state | append-only events; digests; pinning REAL but off on prod; agent loop not durable (restarts from turn 1) | pinning on, durable agent loop, recorded tool results | **NoETL wins**, by construction |
| Observability | whatever the bot logs | per-step and per-agent-turn events; token usage in `call.done`; no token or fuel metric | metrics for tokens, fuel and slot occupancy | **NoETL wins** |
| Sharing between bots | shared files (mutable, unsafe) | content-addressed catalog and result store; sharing by digest, not mutable state | the same, plus per-bot artifact namespaces | **NoETL wins** |

### 2.1 Isolation and security boundary

**What NoETL does today (REAL)**
- **Execution-scoped keychain.**
  - A playbook declares `keychain:` entries. A worker resolves `{{ keychain.<alias>.<field> }}` by asking the server,
    and never reads the secret store itself (`worker/src/executor/keychain_namespace.rs`).
  - The server resolves a keychain alias against **the execution's own playbook** (catalog id from the start event)
    and caches it per execution (`server/src/services/credential.rs`, `try_resolve_keychain`, from line ~174).
  - So a playbook gets the keychain entries it declares.
- **Secrets Wallet.**
  - GCP, AWS, Azure, Vault and Kubernetes providers resolve at execution time over Workload Identity; this is live on
    prod (`secret-manager-retrieval.md` §1.5).
  - Sealed delivery encrypts a credential to a registered worker public key (`server/src/handlers/credentials.rs`
    `get_sealed`, line 226).
  - Residency policies exist: none, advisory, or strict, which fails closed (`server/src/secrets/residency.rs`).
- **WASM.**
  - A compiled pure playbook is a module with no ambient I/O.
  - The worker enforces fuel (DEFAULT 10e9), a wall-clock limit (DEFAULT 30 s) and linear memory (DEFAULT 1024 MiB),
    and counts trips (`worker/src/plugin.rs:41-47`, worker#399).
- **`kind: container`.** The step runs as a separate Kubernetes Job; the worker frees its slot and waits for a callback
  (`worker/src/executor/command.rs:1430-1468`). This is the only step kind with a pod boundary today.
- **Agents.**
  - The hosted loop has a tool-call budget the model cannot raise (`NOETL_AGENT_MAX_TOOL_CALLS`, DEFAULT 32) and a
    child timeout (`NOETL_AGENT_TOOL_TIMEOUT_SECS`, DEFAULT 180).
  - The `claude-code` agent subprocess strips the Anthropic key variables from its environment
    (`tools/src/tools/agent.rs:912-913`).
  - That is the one place in the tool crate that removes inherited env.

**What NoETL does not do today (REAL gaps)**
- **Shared process, shared pod.**
  - `http`, `postgres`, `duckdb`, `rhai`, `mcp` and `agent` run in the worker's address space.
  - Every user's steps on a pool share the same pods.
  - A `duckdb` query spends the pod's memory limit for everyone on that pod (resource model, `step_kinds`).
- **Subprocesses inherit everything.**
  - `python` and `shell` add per-step env on top of the worker's environment and never clear it
    (`tools/src/tools/python.rs:637-646`, `shell.rs:93-103`). They run as the same uid, with the same filesystem,
    network and pod service account.
  - On the system pool, the worker env carries `NOETL_INTERNAL_API_TOKEN` (`secret-manager-retrieval.md` §1.1).
  - So a python step routed there can read it.
- **Named credentials are not scoped.** `GET /api/credentials/{name}` returns a stored credential found by name before
  any execution check is made (`credential.rs` `get`). Only the keychain *fallback* uses the execution id.
- **The auth gate is in shadow on prod.** It logs "WOULD reject" and rejects nothing (wiki Home, verified state).
- **Sealing is per worker, not per step.** The sealing key identifies a worker process, which serves many tenants'
  steps.

**Conclusion.**
- Today NoETL cannot honestly claim a per-bot security boundary in the cluster runtime.
- It can claim:
  - execution-scoped declared credentials;
  - a real WASM sandbox for pure logic;
  - a real pod boundary for `container` steps;
  - a much better audit trail.
- §7.1 turns these pieces into the boundary.

### 2.2 Cost

The resource model gives no prices, and this document invents none. Use your own `p_cpu` ($/vCPU-hour) and `p_mem`
($/GiB-hour).

| | Shared VM per account (GIVEN) | NoETL user pool (DEPLOYED) |
|---|---|---|
| Provisioned per account at idle | ~8 vCPU, ~16 GB (ballooning may reclaim memory; CPU stays reserved) | 0 |
| Platform floor | — | 2 × (250m, 256Mi) requested = 0.5 vCPU, 0.5 GiB; limits 4 vCPU, 1.5 GiB |
| Platform ceiling | — | 20 × (250m, 256Mi) requested = 5 vCPU, 5 GiB; limits 40 vCPU, 15 GiB, 80 slots |
| Idle cost for N accounts | ≈ N × 8 × p_cpu + N × 16 × p_mem per hour | ≈ the floor, independent of N |

**Worked example.** 100 accounts × 3 bots, each active 5 % of the time:
- **Competitor.** 100 VMs = **800 vCPU** provisioned around the clock (GIVEN size), whatever the activity.
- **NoETL.** Expected concurrent bot steps ≈ 300 × 0.05 = **15**, which needs 4 replicas (16 slots), or 1 vCPU of
  requests and a 8 vCPU limit ceiling.

**Caveats that cut against NoETL**
1. **Slots, not CPU, are the binding resource for agents.**
   - A hosted agent step holds its slot for the whole loop, including every LLM round trip and every awaited
     playbook child. The worst case is 32 tool calls × 180 s ≈ 96 minutes on one slot (resource model, heuristics).
   - Four slots per pod waiting on HTTP use almost no CPU, so agent fleets pay for idle reserved pods.
   - §7.3 fixes this by releasing the slot while waiting.
2. **The floor is not counted in full.** The server StatefulSet, command-bus writer, Postgres and the fixed system pool
   (1.5 vCPU / 6 GiB requested) are platform overhead the resource model does not total. At very small fleets (one or
   two accounts) one VM can be cheaper than a whole NoETL platform.
3. **The competitor may suspend idle VMs.** Firecracker supports snapshots. If idle accounts are snapshotted, their
   idle cost falls; the model as GIVEN says always-on.

**Edge WASM.** A deterministic playbook compiled to WASM costs nothing on the cluster: no slot, no event and no server
round trip (kuksin.us, §2.5). That is cheaper than either model for the deterministic part of a bot's work.

### 2.3 Performance under concurrency

**NoETL scales better**
- When a fleet's work fans out: one execution's parallel loop, inclusive router or `next` list issues every branch at
  once across all replicas of the target pool, with a reduce barrier (REAL, `coroutines.md` §2.1).
- When many bots run at once: their steps spread over 8–80 slots and over separate pods, so one bot's memory-heavy
  `duckdb` query cannot take RAM from bots on other pods.
- In the competitor's model, every bot of an account competes for the same 8 cores and 16 GB, and free memory can fall
  to low single-digit GB (GIVEN).

**NoETL scales worse, or not at all, today**
- **No throttle.** A parallel loop of N items needs N free slots, and the excess queues. Queueing is visible: with 90
  commands offered in 1.2 s against 8 slots, issue → claim was p50 2123 ms / p99 3735 ms (MEASURED, prod 2026-07-30).
- **Self-deadlock risk.** Awaiting parents hold slots while their children need slots on the same small pool (resource
  model, `deadlock_note`).
- **WASM serialises per process.** The worker's WASM dispatcher sits behind a `tokio::sync::Mutex`
  (`worker/src/executor/command.rs:163`), so concurrent WASM steps on one pod run one at a time.
- **Submit concurrency.** `POST /api/execute` at client concurrency ≥ 4 went bimodal with errors and 30 s timeouts
  (MEASURED, prod, server v3.100.4, 2026-09). It has not been re-measured since; sustained executions per second are
  NOT_YET_MEASURED.
- **Scale-up latency.** A new GKE Autopilot node takes ~60–90 s (MEASURED); the KEDA ramp time on the EHDB trigger is
  NOT_YET_MEASURED.

### 2.4 Determinism and observability

**REAL**
- Every step is `command.issued` → `command.claimed` → `command.started` → `call.done` → `command.completed`, stored in
  an append-only event log. `GET /api/executions/{id}` returns up to 2000 events with timestamps.
- Agent loops emit `agent.turn`, `agent.tool_call` (with child execution ids, durations and 2 KiB previews) and
  `agent.final`.
- Playbooks are identified by a `sha256:` digest.
- With `NOETL_CATALOG_PINNING` an execution, and every sub-playbook in its tree, runs one fixed version, across
  instances too (ai-meta#548 §5 and §12).

**Honest limits**
- **Pinning is off on prod** (resource model, DEPLOYED).
- **Replay means reconstruction, not re-execution.** LLM calls are not deterministic. What the log gives is a complete
  record of what each step received and returned.
- **The agent loop is not durable.** If its worker dies, the step restarts from turn 1 and re-runs children that
  already ran.
- **Missing metrics.** There is no metric for tokens, fuel or slot occupancy (resource model, `metrics.not_available`).

The competitor's shared VM has the opposite property: state is whatever is on the disk now. Two bots can silently
change each other's files or sessions, and nothing records who did what.

### 2.5 Edge WASM: the kuksin.us proof (REAL, single deployment)

- The kuksin.us intake chat runs three pure NoETL playbooks (`kuksin/intake/prepare`, `kuksin/intake/finish`,
  `kuksin/contact/build`). They are compiled by `plugins/playbook-wasm` into one module inside a Cloudflare Worker.
- There is no NoETL server round trip, no slot and no event, and the Worker stores nothing.
- The model call (`claude-haiku-5-5`) and the email send happen in the Worker's JavaScript, outside the module.
  Parity with the cluster engine is checked by `wasm/cases.py` and `wasm/parity.mjs`.
- **Latency.** The owner reports ~1.5 s for a first run, then fast. That is consistent with the ~1.5 s first-dispatch
  compile of a ~1.6 MB module MEASURED on a fresh kind worker pod. An edge latency distribution is NOT_YET_MEASURED.
- **Limits of the proof.**
  - Only pure playbooks compile. Anything with I/O (http, keychain, sub-playbooks) runs in the host.
  - It is one deployment, not a fleet benchmark.

---

## 3. Where NoETL genuinely wins (the arguments that hold today)

1. **Cost scales with work, not accounts.** One shared elastic pool with a 0.5 vCPU floor replaces an ~8 vCPU VM per
   account. For any fleet with more than a few mostly-idle accounts, this is an order-of-magnitude argument, and it is
   true today, with the caveats in §2.2.
2. **Horizontal fan-out.** Up to 80 concurrent slots across 20 pods on the deployed user pool, with real fan-in, versus
   one machine per account.
3. **Contention is spread, not concentrated.** One bot's heavy step lands on one pod's limit, not on the whole
   account's machine.
4. **An auditable record of every bot action**, including agent turns, tool calls and token usage, plus digests and
   pinning for reproducible versions.
5. **Sharing without shared mutable state.** Bots share playbooks and results by content digest, through the catalog
   and the result store, instead of through a common writable disk.
6. **Deterministic work can leave the cluster entirely**, as compiled WASM at the edge.

## 4. Where the competitor genuinely wins

1. **Isolation between users is stronger today**: a hardware VM against shared worker pods.
2. **Interactive, stateful, long-lived work**: a desktop, a browser with persistent sessions, sudo, a 128 GB disk that
   survives between tasks. NoETL has no equivalent.
3. **Single-task latency**: a local process has no orchestration hop. NoETL adds ~4.5 s per step and ~9–15 s per hop
   on prod (MEASURED).
4. **Simplicity at tiny scale**: one account, one VM, nothing else to run.

## 5. Honest weaknesses (unsoftened)

| # | Weakness | Evidence | Fixed by |
|---|---|---|---|
| W1 | No per-bot or per-tenant isolation for in-process and subprocess step kinds; subprocesses inherit the worker env | `python.rs:637-646`, `shell.rs:93-103`; resource model `step_kinds` | §7.1 |
| W2 | Named credentials resolve for any caller; the auth gate is shadow on prod; sealing is per worker | `credential.rs` `get`; wiki Home; `credentials.rs:226` | §7.1 |
| W3 | ~4.5 s/step, ~9–15 s/hop, ~82 % of a planner turn is orchestration (2026-08); ~0.95 s/step on the latest measurement (2026-11-02) | resource model, `orchestration_overhead`; §7.0 | §7.0, §7.2 |
| W4 | Not scale-to-zero: user pool min 2; system pool fixed, no autoscaler | resource model, `concurrency.autoscaling` (DEPLOYED) | §7.3 |
| W5 | No backpressure: `max_in_flight` has no reader; awaiting parents hold slots; agent loops hold a slot for up to ~96 min | resource model, heuristics; `coroutines.md` §2 | §7.3 |
| W6 | WASM steps serialise per worker process | `command.rs:163` | §7.2 |
| W7 | No desktop, browser or persistent workspace tool | the tool list in `tools/src/tools/` | §7.4 |
| W8 | Agent loop not durable; cancel does not reach children or delegated runs; queued commands claimable after an API cancel | `coroutines.md` §2.1; RFC §12 TARGET list | §7.3 |
| W9 | Key numbers missing: sustained executions/s, KEDA ramp, per-kind step latency on prod, hosted-LLM step latency | resource model, `not_yet_measured` | §8 |

---

## 6. Design principle for the fix

Keep NoETL's strengths: elastic shared compute, the event log, the content-addressed catalog and edge WASM. Move the
**security boundary from the pool to the execution**, and move the **cost boundary from the slot to actual work**.

Each bot gets:
- an **identity** (a principal);
- a **capability set** (which playbook digests it may run, which credentials, which egress hosts);
- an **isolation tier** chosen per step by what the step needs, not by where it happens to land.

## 7. Architecture changes to make it a true win (TARGET)

### 7.0 Where the per-step and per-hop overhead actually comes from — and what cuts it

This section answers four questions directly. Where do the ~4.5 s per step and ~9–15 s per sub-playbook hop come from?
Is it Postgres? Can EHDB fix it? Which design changes actually cut it?

It is built from the measured breakdowns already in this org, not from reading constants in the source.
[#319](https://github.com/noetl/ai-meta/issues/319) records why that discipline matters: a diagnosis built from a
10 s retry constant was refuted by the first counter that could say no.

#### 7.0.1 Evidence base

| Source | Date, environment, build | What it measured |
|---|---|---|
| [#156](https://github.com/noetl/ai-meta/issues/156) per-hop attribution | 2026-06-28/29, prod, server v3.47.0 | hops bimodal: ~0.3 s when the off-server state builder's WAL drain is caught up, ~8 s+ when it misses its 1 s budget and falls to the 8 s reconcile tick; the drive does **not** read `noetl.event` SQL on the hot path |
| [#156](https://github.com/noetl/ai-meta/issues/156) "Trip to Paris" analysis | 2026-06-29, prod | reconcile stalls 8–18 s per turn; fixed per-hop tax ~12 s per turn; provider children mostly orchestration |
| [#155](https://github.com/noetl/ai-meta/issues/155) 10-hop probe | 2026-08-18, kind, trivial python steps | 79 % of a turn was **two command-dispatch gaps per hop**; root cause a missing `noetl.command (event_id)` index |
| [#155](https://github.com/noetl/ai-meta/issues/155) mirror fix | 2026-08-18/20, prod, "trip to Lisbon" | `emit_mirror` 1141.9 ms per call (EHDB reference runtime replaying its whole log per operation) → 0.1 ms; turn ~89 s → ~13 s median warm |
| [#155](https://github.com/noetl/ai-meta/issues/155) planner profile | 2026-08-20, prod, planner v81 | 63 events at a near-uniform 0.8–1.2 s spacing, ~4.5 s per step, 82 % orchestration. Inlining a child removed ~14 s of work and moved wall clock by nothing measurable. |
| [#319](https://github.com/noetl/ai-meta/issues/319) / [Umbrella-Request-Latency](https://github.com/noetl/ai-meta/wiki/Umbrella-Request-Latency) | 2026-09-03, prod, server v3.100.x | raw EHDB append ~4 ms (fsync per record); Postgres round trip 13–20 ms from the server pod; `/api/execute` = 10 sequential Postgres calls ≈ 97 % of an uncontended request |
| PR [#355](https://github.com/noetl/ai-meta/pull/355) RFC `ehdb-execution-partitioned-event-store.md` | 2026-09-24, open | per-execution chain reads are O(total records): a global sequence, linear subject filter, one mutex per store |
| "Ranch concierge latency breakdown" session (shastaranch PR #13) | 2026-11-02, prod, server v3.147.0, n=4 | `concierge/turn` p50 8.69 s with 1.84 s of tool time over 7 steps: **~0.95 s dispatch overhead per step**, split ~0.46 s before `command.issued`, ~0.33 s to claim, the rest reporting |
| Resource model | as_of 2026-11-11 | issue → claim p50 138.5 ms unsaturated vs 2123 ms with 90 commands against 8 slots (prod, 2026-07-30); server ingest ~336 ms / ~1021 ms per emit on prod vs ~40 ms on kind (metric doc comment, written during #155) |

⚠ **The ~4.5 s per step is an August figure and is stale as a current number.** Several fixes landed after it:
- the mirror off the request path, 2026-08-19;
- re-trigger on clear for the lost-wakeup 8 s stall, server v3.82.0;
- the #503 ~6 s server stall, server v3.146.1.

The latest measured per-step overhead is **~0.95 s** (ranch concierge, 2026-11-02). Prod planner turns fell from
76–107 s (2026-08) to **17.0–21.2 s** (2026-11-04). The ~9–15 s per hop is also from August and has not been
re-measured since (NOT_YET_MEASURED). The resource model's caveat already says this; this section makes it explicit.

#### 7.0.2 Anatomy of one step (REAL path; current prod shape)

```
worker A finishes tool
  ├─ POST /api/events  command.completed, call.done      ← server ingest per emit: catalog lookup, normalize,
  │                                                         Postgres INSERT, EHDB feed publish, async mirror enqueue
  ├─ server trigger_orchestrator → issues __orchestrate__ as a COMMAND to the system pool   (dispatch #1)
  │     system worker claims → state builder serves this execution's state from its in-memory WAL index
  │     (fed by the EHDB events feed) → WASM orchestrate run → next commands returned to server
  ├─ server: command.issued  → Postgres command row + EHDB command-bus append (~4 ms fsync)  (dispatch #2)
  ├─ worker B (user pool) parked in claim_next → bus delivery (µs) → POST /api/commands/{event_id}/claim
  │     → server resolves the command row in Postgres → command.claimed
  └─ worker B: command.started → tool runs → call.done → command.completed   (and the cycle repeats)
```

**Attribution of the ~0.95 s per step** (MEASURED prod, 2026-11-02, n=4; the split is the session's, the mapping to
mechanisms is from the path above):

| Segment | Time | What is in it | Dominant contributor |
|---|---|---|---|
| `command.completed` → `command.issued` | ~0.46 s | ingest of the completion events, dispatch #1 (orchestrate as a system-pool command), state serve, WASM drive, issue | **the drive is itself a dispatched worker command**: two handoffs per step (#155: 79 % of a probe turn) |
| `command.issued` → `command.claimed` | ~0.33 s | bus delivery (µs, #205), claim round trip to the server, Postgres command lookup | the claim RTT; in kind before the index it was 559 ms, after it 60 ms (#155) |
| reporting (`started`, `call.done`, `completed`) | ~0.16 s | three ingest calls per step | Postgres INSERT + feed publish per emit |
| tool work | 0.02–1.2 s per step | the actual step | — |

**Why a hop costs far more than a step.** A `kind: playbook` child is a whole execution:
- `POST /api/execute`: about 10 sequential Postgres calls, ~150 ms uncontended (#319).
- The child's own `start`, the real step(s) and `end`, each paying the per-step cost.
- The playbook lifecycle events.
- The parent step's own lifecycle.
- The parent's **await poll**, which ticks every 2 s (`poll_interval` default 2, minimum 1;
  `tools/src/tools/playbook.rs:463`). Completion is noticed 0–2 s late, ~1 s on average.

That puts a hop at roughly `(child steps + 1) × per-step + ~0.15 s submit + U(0, 2) s poll`. With August's per-step
cost (~3–4.5 s) and a three-step child, that is 9–15 s, which matches the measurement. With November's ~0.95 s it
predicts **~3–5 s per hop** (GUIDANCE arithmetic; NOT_YET_MEASURED).

**Polling and cadence inventory** (REAL):

| Interval | Value | Where | Effect on latency |
|---|---|---|---|
| `kind: playbook` await poll | 2 s (configurable, ≥ 1 s) | `tools/src/tools/playbook.rs:463` | 0–2 s per awaited hop, and holds the parent's slot while it waits |
| cross-instance delegate poll (A's worker → A → signed → B) | 2 s | `catalog_remote` + tools 4.6.0 (RFC §12) | 0–2 s per delegated call, plus one signed request to B per tick |
| reconcile poller | 8 s | `server/src/handlers/events.rs` `RECONCILE_INTERVAL` | only on a missed trigger. The lost-wakeup cause is fixed: `NOETL_ORCH_RETRIGGER_ON_CLEAR`, v3.82.0; stalls 3/40 → 0/30 (#155). |
| claim coordinator park | 250 ms cap | EHDB command source | a cap on the park, not a floor; the claim path is 16–33 µs (#205) |
| KEDA polling / cooldown | 10 s / 30 s | ScaledObject (DEPLOYED) | scale-up reaction time, not per-step cost |

**Cold starts** (MEASURED or DEPLOYED):
- **User pool.** It does not scale from zero today (min 2), so a step never waits for a pod from zero. A burst that
  needs a new GKE Autopilot node waits ~60–90 s.
- **System pool.** A fresh pod after a roll stalls its first drives for **7–10 minutes** while the state builder
  replays the feed (2026-11-03).
- **WASM.** A first dispatch costs ~1.5 s of Cranelift compile, and the drive pool pre-compiles at boot.
- **Implication.** Scale-to-zero (§7.3) would add a pod start (and possibly a node) to the first step of every burst
  on that pool. It must not be applied to latency-sensitive pools without a warm floor.

#### 7.0.3 Is Postgres the bottleneck?

**Partly. The premise needs one correction.**

1. **Raw Postgres latency is not the bottleneck, but it is not single-digit ms either.**
   - One round trip from the server pod through pgbouncer → cloud-sql-proxy → Cloud SQL measured **13–20 ms**
     (#319).
   - A step makes roughly 5–10 such calls: an INSERT per lifecycle emit, catalog lookups, the command row and the
     claim lookup. That is **~75–150 ms of a ~0.95 s step, about 10–15 %**.
   - The other ~85 % is the orchestration pattern: two dispatches per step, an HTTP claim, per-emit ingest, polling
     on hops, and cadence.
2. **Postgres *access patterns* have twice been the dominant cost, and one fix is still not on prod.**
   - **The claim lookup.** It resolved a command by `event_id` on a table hash-partitioned by `execution_id`, whose
     every index leads with `execution_id`. Each claim was a parallel seq scan over 16 partitions: 88,199 buffers,
     ~295 ms, twice per hop.
   - Adding `idx_command_event_id` took the kind probe from **20.7 s → 4.3 s** (4.8×), issue → claim from
     559 → 60 ms, and variance from ±40 % to ±1 % (#155, noetl#696).
   - It is **still not applied on prod**: [#283](https://github.com/noetl/ai-meta/issues/283), blocked on a superuser
     `GRANT`, is open. Prod's current state was not re-verified for this RFC.
   - The table grows with every command, so this cost grows with time.
   - **`/api/execute`.** Ten sequential round trips are ~97 % of an uncontended submit (#319). Four catalog reads were
     reduced to one in server#394.
3. **The state-rebuild read is not a Postgres read on the hot path.**
   - The off-server drive serves state from the system worker's in-memory WAL index, fed by the EHDB events feed. It
     does **not** read `noetl.event` per step; #156 corrected exactly this hypothesis on 2026-06-29.
   - The rebuild costs that do exist are EHDB-side and O(log size):
     - the reference runtime replayed its whole JSONL log per operation (1.14 s per mirror call; fixed by the
       runtime cache);
     - per-execution chain reads are a linear filter over every record behind one mutex per store (PR #355 §1.3,
       still open);
     - a fresh system-pool pod replays the feed for 7–10 minutes.
   - Postgres `noetl.event` reads remain on side paths: keychain resolution reads the start event, plus the reconcile
     and status APIs.

**Verdict.**
- The per-step cost is dominated by the orchestration pattern (two dispatches, the HTTP claim, per-emit ingest,
  polling) and by O(size) access patterns, wherever they live.
- Raw Postgres round trips are ~10–15 % of a step today.
- The single cheapest per-step fix available is a Postgres index that is already written (#283).

#### 7.0.4 Can EHDB fix it?

**What EHDB already fixed (REAL, MEASURED).**
- EHDB replaced NATS on the command bus (2026-07-27).
- Delivery is 0–2 µs, the claim path 16–33 µs, publisher-mutex wait 0 µs (#205, #319).
- The bus is no longer a meaningful part of a step. Its floor is the ~4 ms per-append `fsync` (`FlushPolicy::EveryAppend`).
- Group commit already exists in the engine (`append_batch`), but adopting it is a durability decision parked behind
  [ehdb#322](https://github.com/noetl/ehdb/issues/322).

**What EHDB as the state substrate would add (TARGET; PR #355, ai-meta#455).**
- **One durable write per event instead of three paths.** Today an emit is a Postgres INSERT, a feed publish and an
  async mirror append. One append with execution-partitioned storage removes the INSERT (~15–20 ms per emit, about
  three per step) and makes the mirror unnecessary.
- **O(execution) chain reads.** The drive's state is served from the execution's own partition, locally, instead of
  from a global-sequence filter or a feed replay. This removes the 7–10 minute fresh-pod replay and the
  read-timeout → re-drive loop that the 8 s reconcile backstops (PR #355 §1.5, §6.2).
- **The claim lookup moves off Postgres.** The command is resolved from the bus record it was delivered with.
- **Estimated gain: ~0.1–0.4 s per step** of today's ~0.95 s: the INSERTs and Postgres claim lookup plus tail and
  stall removal. The upper end applies only if #283 is still unapplied. TARGET estimate; it must be measured.

**What EHDB alone does not fix. Said plainly:**
- **the two dispatches per step**: the drive is a separate worker command whatever store it reads;
- **the 2 s await poll** on `kind: playbook` and on cross-instance delegate;
- **cold starts**: node provisioning, pod scheduling, WASM compile;
- **the 4 ms fsync per append**, unless group commit is adopted;
- **per-step lifecycle chatter**: three ingest calls per step, whatever the store.

#### 7.0.5 Design changes that cut it, ranked by expected impact

This ranks by expected wall-clock removed from a typical multi-step bot turn. It differs from the order in the
request in one place: push completion is the biggest fix for *hop variance and slot holding*. But the child's own
steps, not the poll, are most of a hop, so step collapse ranks higher.

| Rank | Change | What it removes | Expected impact | Label / dependency |
|---|---|---|---|---|
| 0 (do now) | Apply the `noetl.command (event_id)` index on prod (#283) | the claim's partition seq scan | kind: issue → claim 559 → 60 ms, turn 4.8× faster on the probe; prod: up to ~0.3 s per claim, growing with table size | REAL fix, merged (noetl#696), blocked only on an owner-run `GRANT` |
| 1 | **Collapse deterministic step chains into one run**: compiled WASM in-worker (§7.2 items 1–2) or at the edge (kuksin.us) | every per-step dispatch, claim and lifecycle emit inside the segment; inlines pure children, which removes whole hops | for N fused steps: (N − 1) × ~0.95 s → ~0; a pure child hop → a function call. kuksin.us has zero cluster round trips per step. | REAL engine (`plugins/playbook-wasm`), REAL edge proof; in-worker fusion TARGET |
| 2 | **Worker-local continuation + in-process tool-list batching.** The worker that finishes a step runs the WASM drive for that execution and claims its own next command when it targets the same pool. An ordered tool list already runs in one command (`task_sequence`). | dispatch #1 (orchestrate as a separate command) and the re-claim | ~0.46 + ~0.33 s → an estimated ~0.1–0.2 s per step | TARGET; needs a per-execution lease so two workers never drive one execution (the #155 single-drive guard generalised) |
| 3 | **Push completion instead of polling**: a child's terminal event, and B's for delegation, wakes the parent through the event it already emits; the parent's slot is released while waiting (§7.3 item 3) | U(0, 2) s per awaited hop; one signed request per 2 s for delegate; slot-holding deadlock risk | −1 s mean / −2 s max per hop; plus slot capacity back | TARGET; the coroutines RFC (#554) and RFC §12 both list it |
| 4 | **EHDB state substrate** (PR #355) | the Postgres INSERT per emit; O(global) chain reads; fresh-pod replay; the re-drive / 8 s reconcile tail | ~0.1–0.4 s per step; removes 7–10 minute post-roll stalls and the bistable tail | TARGET; multi-phase migration |
| 5 | **Warm floors on latency-sensitive pools, scale-to-zero only on cost pools** | node and pod cold start on the first step of a burst | avoids a 60–90 s node wait or a pod start; keeps the current ~138 ms unsaturated claim | DEPLOYED today (min 2); the TARGET is to make it a per-pool choice |
| 6 | **Group commit on the EHDB append** (ehdb#322) | ~4 ms fsync per record | a few ms per append; mostly a throughput and capacity win (~250 appends/s single-writer ceiling, #319), not per-step latency | owner's durability decision |

#### 7.0.6 Target per-step budget if these land

All TARGET figures are arithmetic from the measured components above. Each must be re-measured on the 10-hop probe
(`diag/latency-probe-10hop`) and on a real concierge and planner turn before it is quoted.

| State | Orchestration per step | Per awaited hop | Basis |
|---|---|---|---|
| Today | **~0.95 s** (MEASURED, 2026-11-02) | ~3–5 s predicted (9–15 s MEASURED in 2026-08) | §7.0.2 |
| + #283 index | ~0.7–0.9 s | −0.3 s per child step | kind delta, scaled down because prod's claim share is already ~0.33 s |
| + EHDB state substrate | ~0.5–0.6 s | same, minus the post-roll stalls | §7.0.4 |
| + worker-local continuation | **~0.15–0.3 s** | child steps × that, + ~0.15 s submit | one dispatch per step instead of two |
| + push completion | unchanged | **no poll term**; slot released while waiting | §7.0.5 rank 3 |
| Fused segment / inlined pure child | **< 10 ms per fused step** (in-process call), one boundary per segment | 0 for a pure child | WASM dispatch is in-process once compiled |
| Edge WASM | **0 cluster overhead** | n/a | kuksin.us |

**Worked example: `concierge/turn`** (7 steps, 1.84 s of tools, p50 8.69 s today).
- At ~0.25 s per step it would be ~1.84 + 7 × 0.25 ≈ **3.6 s**.
- If the three post-reply logging steps are also fused into one segment, it would be ~**3.1 s**.
- The reply-ready point, today ~4.3 s, would fall to ~**2.1 s**, dominated by the 1.2 s model call.

That is the honest end state: **the model call and the tool work dominate, not orchestration**. That is when NoETL's
per-step overhead stops losing to a warm single VM on latency, while keeping the cost and fan-out advantages in §3.

### 7.1 Per-bot sandbox + credential capability model (fixes W1, W2)

1. **Bot identity.**
   - A bot is a principal: an id, an owning tenant, and a capability manifest stored in the catalog by digest.
   - Every execution carries `principal` in its start event, and every command carries it. The orchestrator copies it;
     steps cannot change it.
2. **Isolation tiers, chosen per step.**
   - **T0, pure:** a compiled WASM module with no host imports. Runs in-worker or at the edge.
   - **T1, capability WASM:** a WASM component whose only host functions are the ones the manifest grants (http to
     allowlisted hosts, named keychain fields, result put/get). This replaces in-process `rhai` and covers most glue
     logic.
   - **T2, sandbox pod:** for `python`, `shell`, `duckdb` and agent tool code from untrusted sources.
     - One pod per execution or per step, built on the `kind: container` Job path that exists today.
     - A `RuntimeClass` of gVisor, or Kata for Firecracker-grade isolation.
     - `env` cleared to an allowlist; `automountServiceAccountToken: false`.
     - A NetworkPolicy denying egress by default and allowing the manifest's hosts.
     - A read-only root and an ephemeral scratch volume.
   - **T3, session sandbox:** §7.4.
   - **Default rule:** a step runs in the cheapest tier that can satisfy it. A playbook not marked trusted by its
     tenant cannot use in-process kinds on a shared pool.
3. **Immediate hardening, small and independent of the rest:**
   - `env_clear()` plus an explicit allowlist for the `python` and `shell` subprocesses;
   - drop the internal token from worker env where it is not needed;
   - move the auth gate from shadow to enforce after a shadow-log review.
4. **Credentials as capabilities.**
   - `GET /api/credentials/{name}` with data is allowed only when the requesting execution's principal holds that
     credential in its manifest and the command's playbook digest is permitted.
   - A credential is minted short-lived where the provider supports it (STS, GCP IAM, OAuth).
   - It is sealed to a **per-command** ephemeral key, not the worker's long-lived key, so a co-tenant step on the same
     worker cannot unseal it.
   - Global named credentials become tenant-owned records.
5. **Result.** Two bots of the same user hold different credentials, run in different sandboxes, and share only what
   they share by digest. In the competitor's model that is impossible by construction.

### 7.2 Collapse orchestration overhead (fixes W3, W6)

1. **Fused segments.**
   - When a run of consecutive steps is deterministic routing around tool calls that need no other pool, the server
     issues **one** command for the whole segment.
   - The worker drives the segment locally with the same orchestrate-core logic, already compiled to WASM and running
     off-server since #108, and emits the per-step events in one batch at the end.
   - The event log keeps per-step granularity; dispatch, claim and the three emits are paid once per segment instead
     of once per step.
2. **Inline pure sub-playbooks.** A `kind: playbook` call to a digest that compiles to WASM runs in-process as a
   module call instead of a child execution. The measured cost of a hop is ~9–15 s; inlining by hand already cut a
   planner turn by 44 % (MEASURED, prod 2026-06-29).
3. **Remove the WASM mutex.** Use a per-module instance pool, with wasmtime's pooling allocator, so N slots run N
   modules concurrently.
4. **Edge first for deterministic work.** Publish compiled modules by digest from the catalog so an edge host can
   fetch, verify and run them. kuksin.us does this by hand today.
5. **Budget.**
   - Under 100 ms orchestration per fused step and under 1 s per inlined hop (TARGET).
   - Gate each change on a re-measure of the planner turn and the 10-hop probe; the 2026-08 baselines are 82 % and
     79 % orchestration.

### 7.3 True elasticity: scale-to-zero, backpressure, slot release (fixes W4, W5, W8)

1. **Scale-to-zero agent and user pools.**
   - KEDA `minReplicaCount: 0` on the command-bus lag trigger.
   - A small always-warm tier with pre-compiled WASM covers the first request, with the fused-segment drive pool
     pre-compiling at boot as the drive pool does today.
   - The system pool gets its ScaledObject applied.
   - The added cold-start cost, a new pod plus possibly a new node (~60–90 s on Autopilot), has to be measured and
     weighed per pool. Latency-sensitive pools may keep a min of 1.
2. **Coroutines stage 1** (`coroutines.md`):
   - spawn / join / race with enforced `max_in_flight`;
   - cancellation that reaches children and delegated runs;
   - per-tenant concurrency quotas, as fair share across bots, so one bot's fan-out cannot starve the fleet.
3. **Release the slot while waiting.** An agent step waiting on an LLM response, or a parent waiting on a child,
   parks its state and frees its slot; the completion event re-dispatches it. This is the callback pattern
   `kind: container` already uses. It turns agent fleets from slot-bound into CPU-bound, and it also makes the agent
   loop durable, because the parked state is the resume point.
4. **Metrics.** Slot occupancy, tokens and fuel as Prometheus series, so cost per bot is measured, not estimated.

### 7.4 Stateful bots without an always-on VM per account (addresses W7)

- For bots that need a desktop, a browser with persistent sessions, or a workspace, add a **session sandbox** step
  kind (T3).
- It is an on-demand pod or microVM (Kata/Firecracker RuntimeClass) **per bot session**:
  - a headless browser and screen;
  - a persistent volume that is snapshotted to the object store between sessions and restored on resume;
  - suspend after an idle timeout.
- Credentials and egress follow §7.1.
- This concedes that the competitor's model is right for this workload. NoETL's version is per bot, not per account,
  and it is billed while active, not always on.

### 7.5 Target architecture in one picture

```
             tenant / bot principal + capability manifest (catalog, by digest)
                                   │
   POST /api/execute ──► server (pinned digest, principal on every command, enforced auth gate)
                                   │  fused segments, coroutine scheduler, per-tenant quotas
          ┌───────────────┬────────┴─────────┬──────────────────┬──────────────────┐
          ▼               ▼                  ▼                  ▼                  ▼
   T0/T1 WASM        T0/T1 WASM         T2 sandbox pod      T3 session         cross-instance
   at the edge       in worker          (gVisor/Kata,       sandbox (desktop,  delegate (#548 §12)
   (no slot,         (instance pool,    env cleared,        browser, snapshot/
    no server)       no mutex)          egress-deny)        suspend per bot)
          │               │                  │                  │
          └───────────────┴──── credentials: short-lived, sealed per command, only those in the manifest
                                   │
                    append-only event log  ·  content-addressed results  ·  metrics per bot
```

---

## 8. What must be measured before any claim is published

| Claim | Measurement | Status |
|---|---|---|
| Cost per active bot-hour | slot occupancy × pod requests, per pool, under a fleet load test | NOT_YET_MEASURED (no occupancy metric) |
| Fused-segment overhead | per-step orchestration before and after on the 10-hop probe and the planner turn | NOT_YET_MEASURED (TARGET under 100 ms) |
| Scale-from-zero latency | first command claimed after an idle period, per pool | NOT_YET_MEASURED |
| Sustained executions per second | load test on prod-equivalent kind and prod | NOT_YET_MEASURED |
| Edge WASM latency | p50/p95 of a kuksin.us turn, split into WASM and model time | NOT_YET_MEASURED |
| Sandbox pod overhead | T2 start-to-first-instruction with gVisor or Kata on GKE | NOT_YET_MEASURED |

## 9. Staged plan (all flag-gated, off by default, nothing to prod without an owner decision)

| Stage | Change | Flags (TARGET names) | Wins it makes true |
|---|---|---|---|
| 1 | `env_clear` + allowlist for python/shell; drop the internal token from user-reachable env; auth gate shadow → enforce | `NOETL_SUBPROCESS_ENV_ALLOW`; the existing `NOETL_INTERNAL_AUTH_MODE` | closes the worst part of W1/W2 |
| 2 | Principal on executions; credential capability check; per-command sealing | `NOETL_PRINCIPALS`, `NOETL_CREDENTIAL_CAPABILITIES` | credentials per bot |
| 3 | WASM instance pool; inline pure sub-playbooks | `NOETL_WASM_POOL`, `NOETL_INLINE_PURE_PLAYBOOKS` | W6, part of W3 |
| 4 | Fused segments | `NOETL_FUSED_SEGMENTS` | W3 |
| 5 | Coroutines stage 1 + slot release while waiting + quotas | per `coroutines.md` §9 | W5, W8 |
| 6 | T2 sandbox pods via RuntimeClass on the container Job path | `NOETL_SANDBOX_RUNTIME_CLASS` | per-bot boundary for untrusted code |
| 7 | Scale-to-zero pools + warm WASM tier | ops manifests | W4 |
| 8 | T3 session sandbox | `NOETL_SESSION_SANDBOX` | W7 |

Stages 1–3 are small and independent. Stage 1 should go first regardless of the rest, because it is a security fix,
not a feature.

## 10. Open questions

1. Is gVisor enough for T2, or does a multi-tenant agent product need Kata/Firecracker? There is a trade-off in start
   time and GKE Autopilot support (to verify: GKE Sandbox, which is gVisor, is the sandbox GKE offers, and prod runs on Autopilot; Kata would likely
   need Standard node pools).
2. How far can fused segments go before per-step retries and partial failure get hard to reason about? This needs the
   coroutines failure model (§8 of that RFC).
3. Should T3 session sandboxes be NoETL-managed, or delegated to an external sandbox provider through
   `kind: container`?
4. The competitor model is GIVEN, not verified. If the competitor suspends idle VMs or isolates per bot, §2.2 and §2.1
   change, and must be revisited.
