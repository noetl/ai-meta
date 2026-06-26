# RFC — G1 + G2: container/GPU k8s-Job dispatch + long-running async orchestration

- **Status:** Draft / first increment landing
- **Umbrella:** [noetl/ai-meta#139](https://github.com/noetl/ai-meta/issues/139) (Domain-SLM platform), foundations **G1** ([#144](https://github.com/noetl/ai-meta/issues/144)) + **G2** ([#145](https://github.com/noetl/ai-meta/issues/145))
- **Builds on:** the Container Tool Callback umbrella [noetl/ai-meta#43](https://github.com/noetl/ai-meta/issues/43) (Rounds 1–4, already shipped)
- **Relates to:** G3 [#146](https://github.com/noetl/ai-meta/issues/146) (artifact registry — owns the `noetl://` URN refs job inputs/outputs live behind), the off-server drive (#130/#136)
- **Seeds:** travel#70 (G1), travel#71 (G2)

## 0. TL;DR — what already exists, what this RFC adds

The hard part of G1/G2 was built for the Container Tool Callback
umbrella (#43) and is already in `main`:

| Round | Component | Where | State |
| :-- | :-- | :-- | :-- |
| R3 | `Tool::Container` — submits a K8s Job, returns immediately with the `pending_callback` marker | `noetl-tools` `src/tools/container.rs` | shipped (registered in the registry) |
| R4 | Worker honours `pending_callback` — **suppresses its own `call.done`** so the slot frees and the terminal event arrives async | `noetl-worker` `src/executor/command.rs` | shipped (metric `noetl_worker_call_done_skipped_pending_callback_total`) |
| R2 | Server callback endpoint `POST /api/internal/container-callback/{execution_id}/{step}` — emits the resume `call.done` | `noetl-server` `src/handlers/container_callback.rs` | shipped |
| R1 | `noetl-k8s-watcher` — watches Jobs by the `noetl.execution-id` label, POSTs terminal state to R2 | `noetl-ops` `ci/manifests/k8s-watcher/` | shipped (deployed on kind) |

So the **watcher-callback** async path (G2's durable variant) and the
**Job-dispatch tool** (G1's core) already work end to end. This RFC's
increment is the two pieces that the SLM `finetune`/`package` stages
still need and that #43 left out:

1. **G1 — GPU/placement generalization.** `Tool::Container` had no
   `node_selector`, `tolerations`, or `volumes`/`volume_mounts`. A GPU
   training Job needs all three (the GPU *resource request* —
   `nvidia.com/gpu` — already works through the existing `resources`
   passthrough; what was missing is **scheduling onto** a GPU node pool
   and mounting a scratch/output volume). Purely additive config fields.
2. **G2 — poll-based completion fallback.** The only async-resume path
   today is the external `noetl-k8s-watcher` Deployment. Environments
   that don't run the watcher (dev, kind, small single-cluster
   deployments) have no way to resume. This RFC adds a **worker-internal
   poll fallback**, flag-gated and off by default, that watches the
   dispatched Job to terminal state from a detached task (slot stays
   free) and emits the resume `call.done` directly — **no extra
   deployment, no server change, no internal token**.

## 1. G1 — the container/GPU Job tool kind

### 1.1 What ships

`Tool::Container` (`kind: container`) gains three optional config fields,
all pass-through to the K8s `PodSpec`:

```yaml
- step: finetune_slm
  tool:
    kind: container
    image: gcr.io/noetl/slm-trainer:v1
    command: ["python", "-m", "trainer"]
    args: ["--recipe", "qlora"]
    resources:
      requests: { cpu: "4", memory: "32Gi" }
      limits:   { cpu: "8", memory: "64Gi", "nvidia.com/gpu": "1" }   # GPU request — already worked
    node_selector:                       # NEW — land on the GPU pool
      cloud.google.com/gke-accelerator: nvidia-tesla-t4
    tolerations:                         # NEW — tolerate the GPU taint
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
    volumes:                             # NEW — scratch / artifact mount
      - name: scratch
        empty_dir: {}
    volume_mounts:
      - name: scratch
        mount_path: /scratch
    timeout_seconds: 21600               # 6 h hard deadline
    service_account: noetl-container-job
    namespace: noetl
```

- `node_selector` — `map<string,string>` → `PodSpec.nodeSelector`. The
  knob that places a GPU Job on a GPU node pool.
- `tolerations` — list of `{key, operator, value?, effect?, toleration_seconds?}`
  → `PodSpec.tolerations`. GPU node pools are tainted (`nvidia.com/gpu`),
  so a GPU Job must tolerate the taint.
- `volumes` + `volume_mounts` — the minimal subset needed for a training
  Job's scratch space and for mounting a CSI/PVC artifact volume.
  Round-1 subset: `empty_dir`, `persistent_volume_claim`, `config_map`,
  `secret`. Other volume sources are a follow-up.

The GPU *resource request* itself (`limits."nvidia.com/gpu": "1"`)
already worked — `ContainerResources.limits` is a verbatim
`map<string,string>` rendered into K8s `Quantity`. No change there.

### 1.2 Authentication

In-cluster ServiceAccount only — unchanged from #43. The tool builds the
kube client with `Client::try_default()` (reads the worker pod's mounted
SA token + cluster CA). The worker SA (`noetl-worker`) already carries
`batch/jobs: create,get,list,watch,delete` + `pods/log: get`
(`repos/ops/ci/manifests/noetl/rbac.yaml`). No new RBAC for G1.

Per `execution-model.md` secrets rule: business-logic secrets the Job
needs (HF token, teacher API key) are **not** baked into the tool config
as literals — they ride `env[].value_from.secret_name`/`secret_key`
pointing at a cluster Secret the keychain provisioned, or are passed as a
`noetl://` artifact ref the Job resolves via the server API.

### 1.3 Logs + status + result

- **Status** — the dispatch returns a Job handle (`job_name`, `job_uid`,
  `namespace`, labels). Terminal status arrives async (§2) as the
  `call.done` `result.context.terminal_state` (one of `succeeded`,
  `failed`, `failed_image_pull`, `failed_oom`, `failed_node_lost`,
  `failed_timeout`) + `exit_code` + `reason`.
- **Logs** — `stdout_uri`/`stderr_uri` `noetl://` refs on the callback
  (watcher captures them; poll fallback leaves them `None` in round 1 —
  log streaming is on the remaining-work list).
- **Result / artifact ref** — the Job writes its output artifact (a
  trained adapter, a quantized GGUF) to object storage and the
  **artifact URN is returned to the playbook by G3's registry**, not by
  this tool. The contract: the playbook passes the output URN *in* as an
  env var (`OUTPUT_MODEL_URN={{ ... }}`), the Job writes there, and a
  subsequent `register_model` step (G3) records the URN + metrics +
  lineage. This tool stays a thin Job-dispatcher; it does not own
  artifact storage. See [#146](https://github.com/noetl/ai-meta/issues/146).

## 2. G2 — long-running async orchestration

### 2.1 The constraint (execution-model.md callback rule)

A block must not hold a worker slot waiting for an operation that takes
more than a few seconds. An SLM fine-tune is hours. So the dispatch block
returns immediately and the playbook resumes on a completion *signal*.
Three ways to get that signal:

| Variant | Mechanism | Durable across pod restart? | Extra deployment? | Status |
| :-- | :-- | :-- | :-- | :-- |
| **A — watcher callback** | external `noetl-k8s-watcher` watches Jobs cluster-wide, POSTs terminal state to the server callback endpoint | yes (watcher is its own Deployment) | yes (the watcher) | **shipped** (#43 R1/R2) |
| **B — worker poll fallback** | the dispatching worker spawns a detached task that polls the Job to terminal and emits `call.done` itself | no (in-memory; lost if the pod dies) | no | **this RFC** |
| C — Job-watch stream | a long-lived `kube` watch stream instead of poll | no (same as B) | no | follow-up |

**Decision:** ship variant **B** (poll fallback) as the new increment.
Rationale — lowest operational risk for the environments that need it
(no extra Deployment, no internal-token plumbing, reuses the worker's
existing `/api/events` emit path), and it's purely additive: the working
watcher path (A) is untouched. The durability gap is the documented
follow-up (variants A and B together, with the watcher as the durable
backstop and poll as the fast-path / no-watcher fallback).

**Mutual exclusion:** A and B both resolve completion, so running both
against the same Job double-emits the resume `call.done` (different
`event_id`s defeat the server's idempotency). The poll fallback is **off
by default** (`NOETL_CONTAINER_COMPLETION_POLL=false`); turning it on is
a statement that *this* worker resolves its own container Jobs, so the
watcher should not also be running (or should filter out this worker's
Jobs). A future round adds a per-`(execution_id, step)` terminal-dedup
guard (the worker already has a `FinalizedGuard` pattern from #118) so
the two can coexist safely.

### 2.2 The poll fallback — mechanics

```
worker pull loop
   │  claim command (container step)
   ▼
Tool::Container.execute  ── creates K8s Job, returns ToolResult{pending_callback:true, data:{job_name,namespace,...}}
   │
   ├─ pending_callback=true  → worker SKIPS its own call.done   (existing R4 behaviour)
   │
   ├─ NOETL_CONTAINER_COMPLETION_POLL=true AND data has job_name
   │     └─ tokio::spawn(detached poller)            ← slot is NOT held; pull loop continues
   │              │  loop: kube get Job status, backoff (5s→capped), until terminal or deadline
   │              ▼
   │         emit call.done (COMPLETED|FAILED) via ControlPlaneClient.emit_event  → /api/events
   │              (result.context = {terminal_state, job_name, exit_code, reason, completed_at})
   ▼
command handler returns → slot frees immediately
```

The poller is a detached `tokio::spawn` holding cheap clones
(`ControlPlaneClient` — reqwest is `Arc` internally; `Arc<SnowflakeGen>`;
`worker_id`; the identifiers). It calls the new tools-crate helper
`noetl_tools::tools::container::poll_job_to_terminal(namespace, job_name,
PollOptions)` which returns a plain `JobTerminalOutcome { state,
exit_code, reason, completed_at }` — no `kube`/`k8s-openapi` types cross
the crate boundary, so the worker gains no new direct dependency.

### 2.3 Suspend / resume / timeout / failure / retry semantics

- **Suspend** = the worker emits no terminal event when it returns; the
  command is `command.started` with no `call.done`. The orchestrator
  leaves the step in-flight. No slot held.
- **Resume** = the `call.done` (from the watcher *or* the poller) lands
  on `/api/events`; the projector applies it; the orchestrator drives the
  next step. Identical resume path for both variants.
- **Timeout** — two layers: (1) the Job's own `activeDeadlineSeconds`
  (`timeout_seconds`) → K8s kills it → terminal `failed_timeout`; (2) the
  poller's own `max_wait` (`NOETL_CONTAINER_POLL_MAX_WAIT_SECS`, default
  24 h) is a backstop so a poller never runs forever — on poller timeout
  it emits a `FAILED` `call.done` with `reason="poll deadline exceeded"`.
  Layer 1 is authoritative; layer 2 only fires if the watch itself wedges.
- **Failure** — non-success terminal states map to a `FAILED`
  `call.done`; the structured `terminal_state` survives in
  `result.context` so the playbook can branch (e.g. retry on
  `failed_node_lost`, alert on `failed_oom`).
- **Retry** — handled at the **playbook** layer (`retry:` block), not the
  Job (`backoff_limit` defaults to `0`). A retried step dispatches a
  fresh Job with a new `generateName` suffix — idempotent.
- **Cancellation** — out of scope for this increment (remaining work): a
  cancelled execution should `kube delete` the Job. Today the Job runs to
  completion and the resume `call.done` lands on a dead execution → the
  server's stale path (202, counter bumped). Harmless but wasteful.

### 2.4 Tie-in with the off-server drive (#130/#136)

The poll fallback emits the resume `call.done` through the same
`/api/events` ingest the off-server drive already consumes. The terminal
event is an ordinary `call.done` row; the CQRS materializer / state
builder treat it exactly like any tool's completion. No interaction with
the sole-writer/result-tier invariants — the poller writes one event and
returns. The dispatch block freed its slot the moment it returned, so a
6-hour Job never appears in the drive's per-hop latency.

## 3. Observability (observability.md Principle 1)

Each new path ships its three artifacts in the same change set:

- **Span** — `container.poll` span on the detached poller, fielded with
  `execution_id`, `step`, `job_name`, `namespace`.
- **Metrics** —
  - `noetl_worker_container_poll_started_total{namespace}` (counter)
  - `noetl_worker_container_poll_terminal_total{state}` (counter; state
    = succeeded/failed/.../poll_timeout)
  - `noetl_worker_container_poll_duration_seconds` (histogram)
- **execution_id** — every span field + every emitted event carries it.

## 4. Minimal slice shipped in this increment

1. **`noetl-tools` v3.19.0** (PR `feat/g1-g2-container-gpu-async`) —
   `node_selector` + `tolerations` + `volumes`/`volume_mounts` on
   `ContainerConfig`/`build_job` (G1) + the `poll_job_to_terminal` helper
   and `JobTerminalOutcome`/`PollOptions` types (G2), re-exported from
   `tools::mod`. 11 new unit tests (29 container tests total), clippy
   clean.
2. **`noetl-worker` v5.47.0** (PR `feat/g2-container-poll-fallback`) —
   the flag-gated poll fallback in the `pending_callback` arm: a detached
   `spawn_container_poll` task → `poll_job_to_terminal` → emit the resume
   `call.done`. New env flags (`NOETL_CONTAINER_COMPLETION_POLL` +
   `NOETL_CONTAINER_POLL_{INTERVAL,MAX_INTERVAL,MAX_WAIT}_SECS`), new
   metrics. Unit tests for gating + handle extraction + option parsing,
   clippy clean. Depends on tools v3.19.0 (the dep bump to `"3.19"` rides
   this PR; CI green follows the tools release — cross-repo ordering).
3. **`noetl-ops`** — **no manifest change needed for the slice.** The
   `noetl-worker` SA already carries `batch/jobs: create,get,list,watch`
   + `pods/log: get` (`ci/manifests/noetl/rbac.yaml`), which covers both
   the dispatch (create) and the poll fallback (get/watch). The GPU node
   pool (taint + `nvidia.com/gpu` device plugin + accelerator label) is a
   GKE prod-config piece — design captured in §1.1/§5, manifest deferred
   to when the feature deploys. (If the **system worker pool** is ever
   asked to run container tools, its SA `noetl-worker-system-pool` needs
   the same job-read verbs — a one-line ops follow-up.)

### Validation status

- **Unit** — G1 spec translation (node_selector / tolerations / volumes /
  GPU resource passthrough / wire-shape deserialization) and G2
  (`classify_job_status` over `Complete`/`Failed`/running, `PollOptions`,
  worker gating + `extract_job_handle` + env overrides) all pass; both
  crates clippy clean.
- **Live kind end-to-end** — **deferred**, blocked by two independent
  causes documented here so the next session can pick up cleanly:
  1. *Cross-repo ordering* — the worker container image build context
     can't reach the unpublished `../tools` 3.19.0 (the local
     `[patch.crates-io]` works for `cargo` but not the in-Docker build),
     so a poll-path image can't be built until tools v3.19.0 is released.
  2. *Degraded dev cluster* — the local kind cluster was wedged with
     ~59k queued `NOETL_COMMANDS` from a prior runaway PFT
     `task_sequence` loop, starving the worker pool (flagged for a
     controlled drain in a separate task; a force-purge needs human
     authorization).
  The deployed **watcher path** (variant A) already proves the
  dispatch→suspend→resume *mechanics* on kind via
  `repos/e2e/fixtures/playbooks/container_callback_happy_path` (Round 5,
  #43); the poll-path repro below validates variant B once unblocked.

### Poll-path kind validation steps (run once unblocked)

```bash
# 1. publish/patch tools v3.19.0 so the worker image can build, then:
#    (ops) build + load the worker image into kind
# 2. enable the poll fallback + scale the watcher to 0 (mutual exclusion)
kubectl -n noetl set env deploy/noetl-worker-rust \
  NOETL_CONTAINER_COMPLETION_POLL=true NOETL_CONTAINER_POLL_INTERVAL_SECS=2
kubectl -n noetl scale deploy/noetl-k8s-watcher --replicas=0
# 3. dispatch the busybox fixture
curl -sX POST localhost:8082/api/execute -H 'content-type: application/json' \
  -d '{"path":"fixtures/playbooks/container_callback_happy_path","payload":{}}'
# 4. confirm: a noetl-container-* Job is created + Completes; the worker
#    slot frees immediately (no call.done at dispatch); the poller emits
#    the resume call.done; the playbook reaches `end` COMPLETED. Metrics:
#    noetl_worker_container_poll_started_total +1,
#    noetl_worker_container_poll_terminal_total{state="succeeded"} +1.
```

## 5. Remaining work (explicitly NOT in this increment)

- **GPU node pool on a real cluster** — kind has no GPU; the `node_selector`/
  `tolerations`/GPU-request path is validated by spec + a CPU Job. A GKE
  GPU node pool (`nvidia-tesla-t4`/`l4`, taint + device plugin) is the
  prod-config piece. Ops manifest is design-only here.
- **Durable poll / resume across worker restart** — variant B loses the
  poller if the pod dies. The durable answer is variant A (watcher) or a
  reconcile-on-boot sweep (worker lists in-flight `noetl.*`-labelled Jobs
  on startup and re-attaches pollers). Follow-up.
- **Terminal-dedup guard** so watcher + poll can run together safely
  (per-`(execution_id, step)` once-only `call.done`).
- **Cancellation** — `kube delete` the Job when its execution is
  cancelled/superseded.
- **Log streaming** — capture `stdout_uri`/`stderr_uri` on the poll path
  (the watcher already does; the poller leaves them `None`).
- **Bounded poller concurrency** — a flood of long Jobs in one pod spawns
  many pollers; add a semaphore + a gauge.
- **Multi-container / init-container Jobs**, richer volume sources.

## 6. How `slm/finetune` uses this end to end

```yaml
# slm/finetune (sketch) — the SLM fine-tune stage
steps:
  - step: resolve_dataset           # G3: noetl:// URN for the dataset version
    tool: { kind: playbook, path: slm/_resolve_artifact }
  - step: train                     # G1 + G2: the GPU Job, hours-long, slot-free
    tool:
      kind: container
      image: "{{ config.finetune.trainer_image }}"
      args: ["--recipe", "{{ config.finetune.recipe }}"]
      env:
        - { name: DATASET_URN, value: "{{ resolve_dataset.urn }}" }
        - { name: OUTPUT_MODEL_URN, value: "{{ workload.output_model_urn }}" }
        - name: HF_TOKEN
          value_from: { secret_name: slm-secrets, secret_key: hf_token }
      resources:
        limits: { cpu: "8", memory: "64Gi", "nvidia.com/gpu": "1" }
      node_selector: { cloud.google.com/gke-accelerator: nvidia-l4 }
      tolerations: [ { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule } ]
      timeout_seconds: 21600
    # dispatch returns immediately; the playbook suspends here with no slot held.
    # resume lands when the Job terminates (watcher or poll) — `train.terminal_state`,
    # `train.exit_code` are then readable downstream.
  - step: register_model            # G3: record OUTPUT_MODEL_URN + metrics + lineage
    when: "{{ train.terminal_state == 'succeeded' }}"
    tool: { kind: playbook, path: slm/_register_model }
```

The trained-model artifact comes back **not** through the container
tool's return value but through G3's registry: the Job writes to
`OUTPUT_MODEL_URN` (a `noetl://<tenant>/<project>/models/...` URN), and
`register_model` indexes it. The container tool only reports *that the
Job finished and how*.
