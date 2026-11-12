# RFC: coroutines — concurrent units of work inside one execution, on every runtime

Status: **draft for review. Nothing is built; no code PR is open.** Every section labels claims **REAL** (in the code today,
cited) or **TARGET** (proposed here).
Written 2026-11-12 against `main` of server `62137e65` (v3.161.0), cli `72e8122` (v6.4.0), worker `d1c9584` (v6.15.0),
tools `c2e75ee` (v4.6.0), noetl `f562374`.

Related: [`distributed-playbook-catalog.md`](distributed-playbook-catalog.md) (ai-meta#548: the execution pin a coroutine
inherits, §5, and cross-instance delegate, §12), [`interop-missing-tools-build-plan.md`](interop-missing-tools-build-plan.md)
(ai-meta#544: item 8, agents on shared pools with a per-turn record), the resource and performance model
(server#580, `orchestrate-core/schema/resource-model.json`, published as `/dsl/resource-model.json` by noetl.ai#9),
[`dsl-knowledge-base.md`](dsl-knowledge-base.md) (the DSL grammar this extends), and
[`agents/rules/execution-model.md`](../../agents/rules/execution-model.md) (the slot and callback rules this must honour).

## 1. What we want

1. **One model.** Launch N concurrent units of work inside one execution and await all, some, or the first of them, with
   the same meaning on the CLI local runtime and on the distributed runtime (server + worker + noetl-tools).
2. **Structured concurrency.** The execution owns its coroutines. When the owner completes, fails or is cancelled, no
   coroutine keeps running and no child execution is left orphaned.
3. **Cancellation and timeouts** that actually stop work, with a stated bound on how fast.
4. **Concurrency limits** that throttle (today the one that exists is parsed and ignored, §2.2).
5. **A defined failure and durability model**: what join returns on partial failure, and what happens when a worker dies
   mid-unit.
6. **A small DSL surface** that does not contradict the step graph, loops-as-goto, `next` routing, `loop:` or the
   ordered tool list.
7. **Flag-gated, staged, off by default.** The version pin holds: a coroutine runs against the execution's pinned
   playbook version.

## 2. What exists today

"Coroutine" is not a word in the code. The pieces below are what concurrency there is.

### 2.1 Per component

| Component | Async runtime | Concurrency within one execution | Cancellation / timeouts |
|---|---|---|---|
| **CLI** `noetl run -r local` | REAL: one tokio multi-thread runtime (`cli/src/lib.rs:2833`, `block_on` :2841). The engine itself is synchronous: `runner.run()` is called inside the async dispatch (`lib.rs:2025`) and every async tool is bridged with `block_in_place(… block_on …)` (`src/playbook_runner.rs:838, 922, 1545`). | **None.** Steps run as a recursive depth-first walk (`execute_step`, `playbook_runner.rs:396`). Multiple `next` targets run one after another in a `for` loop (:685-700, :764-779). `inclusive` mode only logs (:680, :759). The comment "potentially in parallel" (:513) is not implemented. No join: a target reached from two branches runs twice. Sub-playbooks run synchronously in-process (:984-988). | **None.** Ctrl-C on a local run is a process kill; `ctrl_c` is handled only by `serve` (`lib.rs:3017`). `StepSpec.timeout` is parsed (`executor/src/playbook.rs:251`) and never read; the bridge passes `timeout: None` (`tools_bridge.rs:538, 556`). |
| CLI `serve` | REAL: `Semaphore` sized by `--max-concurrent` (default 4, `lib.rs:336`, `serve/mod.rs:512`), each run in `spawn_blocking` (`serve/mod.rs:608`). | Concurrency is across runs, never within one run. | Shutdown on Ctrl-C only. |
| **server** | REAL: `#[tokio::main]` multi-thread (`src/main.rs:1175`). Background loops are plain `tokio::spawn` (reconcile poller every 8 s `events.rs:3048`; orphan sweep; non-convergence sweep). No `CancellationToken` anywhere. | **Yes, at the step level.** One orchestrator pass returns `Vec<Command>` (`orchestrator.rs:290-302`), so it fans out: `next` as a list, router `spec.mode: inclusive` (`evaluator.rs:110-125, 199-212`), `loop.spec.mode: parallel` (all items at once, `orchestrator.rs:1783-1817`), cursor loops bounded by `frame.row_concurrency` (:1024). **Fan-in exists:** a step with more than one upstream arc waits for every live upstream (the reduce barrier, :688-707, :1385-1460); a loop joins on `iterations_expected` (`state.rs:841-862`), result array in **arrival order**, not index order. One drive per execution at a time (`orchestrate_in_flight`, `src/state.rs:203`). | `POST /api/executions/{id}/cancel` emits **one** `playbook_cancelled` event (`services/execution.rs:1105-1147`); evaluate then stops issuing commands (`orchestrator.rs:396-406`). **Bug:** `claim_command` rejects only `execution.cancelled` (`handlers/events.rs:1049-1066`), so queued commands are still claimable after an API cancel. No cascade to child executions. No step or execution deadline: `ToolCommand.timeout` is always `None` except one hard-coded 30 (`commands.rs:305-610`). On a failed branch the siblings are not cancelled; the terminal decision waits for them (`orchestrator.rs:716-760`). `spec.on_error` is parsed (`playbook.rs:934`) with no reader. |
| **worker** | REAL: `#[tokio::main]` (`src/main.rs:11`). Slots = `WORKER_MAX_CONCURRENT` (default 4) as a `tokio::Semaphore` (`config.rs:115`, `worker.rs:313`). A permit is acquired before pulling, the command is acked right after the HTTP claim, then `tokio::spawn`ed; the permit is held until the tool returns (`worker.rs:750-897`). Pool = `NOETL_FEED_FILTER_SUBJECT` (`worker.rs:233-244`). | **None inside a command.** An ordered tool list runs as `task_sequence`, strictly in order (tools `task_sequence.rs:394`). WASM runs behind a per-process mutex (`executor/command.rs:163, 2415`), so WASM steps serialise per worker. Only exception that frees a slot early: a container Job is watched by a detached poll task (`command.rs:1430-1468`). | **No mid-run cancel** (`cancel` appears only as event-name handling). No per-command timeout (`command.rs:862-887`). Heartbeats are per worker (15 s). Because the bus is acked at claim, a worker death means **no redelivery**; the server's orphan sweep (off by default) fails the execution. SIGTERM drains for `NOETL_WORKER_DRAIN_TIMEOUT_SECS` (150 s). |
| **noetl-tools** | REAL: `#[async_trait] Tool::execute` (`registry.rs:174-193`). Blocking engines use `spawn_blocking` (duckdb :360, rhai :318); python and shell are async subprocesses. | **None** (no `join_all` / `FuturesUnordered` / `JoinSet` in the crate). `kind: playbook` is async by default (returns `{execution_id}`, `playbook.rs:438-453`); with `return_result` / `return_step` it **polls every 2 s while holding the caller's slot** (:456-490), timeout 180 s / 300 s. | `ToolConfig.timeout` exists and `registry.execute` does not enforce it (:242-261). Real timeouts only in shell / python (kill the child), reqwest clients, mcp (`NOETL_MCP_REQUEST_TIMEOUT_SECONDS`). On a `kind: playbook` wait timeout the **child is not cancelled**. No `CancellationToken`. |

### 2.2 DSL constructs that touch concurrency

| Construct | Distributed | CLI local |
|---|---|---|
| `next` list / router `spec.mode: inclusive` | REAL parallel fan-out + reduce barrier | REAL routing, **sequential**, no barrier |
| `loop:` `mode: sequential \| parallel \| cursor` | REAL (`orchestrate-core/src/playbook.rs:704-816`) | **Parsed, never executed**: `loop_config` is `#[allow(dead_code)]` (`cli/executor/src/playbook.rs:222-225`); the step's tool runs once. `RuntimeCapabilities::local()` still advertises `loop_v1` (:67). |
| `loop.spec.max_in_flight` | **Parsed, no reader** (`playbook.rs:780`; resource-model says so, `resource_model.rs:308`). A parallel loop dispatches every item at once. | n/a |
| Ordered tool list (`tool:` as a list, `do: continue\|break\|fail\|jump\|retry`) | REAL, strictly sequential (`task_sequence`) | **Not supported** (`Step.tool` is a single enum) |
| Loops-as-goto (back-edge `next`) | REAL, no server cap; the arc's `when:` is the only bound | REAL as recursion, no cap |
| `kind: playbook` | Child execution with `parent_execution_id`; async or slot-holding poll | Synchronous in-process |
| `kind: agent` | Tool calls within a turn run **sequentially** (`agent_host.rs:256`); budget `NOETL_AGENT_MAX_TOOL_CALLS` 32, child timeout `NOETL_AGENT_TOOL_TIMEOUT_SECS` 180; **not durable**: worker death restarts from turn 1 and re-runs children (`agent_host.rs:30-33`) | Sequential, in-memory |
| `spawn` / `await` / `join` / `select` / `async:` / `concurrency:` | **Not found** | **Not found** |

### 2.3 What this gets wrong

- **Two runtimes disagree.** The same playbook runs branches in parallel with a barrier on the cluster and sequentially,
  without a barrier (a join target runs twice), on the CLI. A `loop:` iterates on the cluster and runs once locally.
- **No `any` / `race` / `settled`.** The only join is "wait for all", and a failure does not stop siblings.
- **Limits do not limit.** `max_in_flight` is ignored. The resource model's guidance is "count slots, not steps".
- **Awaiting holds a slot.** `return_result` polls from a worker slot; the resource model records the deadlock risk when
  awaiting parents fill the pool their children need. This breaks the callback rule in `execution-model.md`.
- **Cancel does not stop work.** No cascade, a claimable-after-cancel bug, no cooperative cancel point in the worker.

## 3. The model (TARGET)

### 3.1 Definitions

- A **coroutine** is one unit of work launched by a step and owned by the execution. A unit is a **leaf**: either
  - a **tool unit**: one tool invocation (or one ordered tool list), the same body a step has today; or
  - a **playbook unit**: one child execution (`kind: playbook` semantics, `parent_execution_id` set).

  A unit does not contain the parent's graph control flow. Branching, back-edges and routing stay in the step graph.
  Anything that needs its own graph is a playbook unit. (This is the main open decision, §11.)
- A **group** is the set of coroutines one step launches. The step that declares the group is its **owner step**. The
  owner step is complete when the group's **join policy** is satisfied; then its `next` arcs evaluate as today.
- **Structured concurrency:** every coroutine has exactly one owner (group → owner step → execution). A coroutine cannot
  outlive its group. The group cannot outlive its execution.

### 3.2 Operations

| Operation | Meaning | Expressed as |
|---|---|---|
| spawn | Start a unit, subject to the group's `max_in_flight` and the execution cap | an entry in `spawn.units` (or one per item with `spawn.each`) |
| await / join | Block the owner step until the policy is met | `spawn.join` (default `all`) |
| select / race | Complete on the first unit to finish, cancel the rest | `join: race` (first to settle) or `join: any` (first to succeed) |
| cancel | Stop a unit or the group | automatic on policy satisfaction, owner timeout, execution cancel/failure; explicitly via the cancel API |

### 3.3 Join policies

| Policy | Owner step completes when | Owner step fails when | Losers |
|---|---|---|---|
| `all` (default) | every unit succeeded | the first unit fails (fail-fast) | cancelled on failure |
| `settled` | every unit reached a terminal state | never because of a unit (inspect `results`) | none |
| `any` | the first unit succeeds | every unit failed (error = aggregate) | cancelled on first success |
| `race` | the first unit reaches any terminal state; its outcome is the step's outcome | the first terminal unit failed | cancelled on first terminal |
| `{ at_least: k }` | k units succeeded | success becomes impossible | cancelled once k reached |

`all` with fail-fast differs from today's reduce barrier, which waits for siblings. The barrier is unchanged; only a
`spawn:` group uses these rules.

### 3.4 Result shape

The owner step's result, readable downstream as `{{ <owner>.… }}`:

```yaml
policy: all
status: succeeded            # succeeded | failed | cancelled | timed_out
winner: flights              # any / race only
results:                     # keyed by unit name, in declaration order (each: index order)
  flights: { status: succeeded, result: {...}, started_at: ..., ended_at: ..., attempts: 1 }
  hotels:  { status: cancelled, reason: lost_race }
errors: []                   # one entry per failed unit: { unit, kind, message }
```

Results follow declaration (or item) order, not arrival order. Today's loop join returns arrival order
(`state.rs:841-862`); a `spawn.each` group does not inherit that. Large unit results spill to the result store by
the existing `NOETL_EVENT_RESULT_CONTEXT_MAX_BYTES` rule.

## 4. DSL surface (TARGET)

One new step field, `spawn:`. A step with `spawn:` has no `tool:` of its own. It does not conflict with `loop:`,
`next:` or the ordered tool list: `spawn:` is rejected together with `loop:` on the same step (use `spawn.each`), and a
unit's `tool:` may be an ordered tool list.

```yaml
- step: gather
  spawn:
    join: all                 # all | settled | any | race | { at_least: 2 }
    max_in_flight: 3          # optional; bounded above by the execution cap
    timeout_s: 120            # group deadline; units still running at the deadline are cancelled
    restart: never            # never | replay   (§8; default never)
    units:
      - name: flights
        tool: { kind: http, url: "{{ workload.flights_api }}", method: GET }
        timeout_s: 30         # per unit
      - name: hotels
        playbook: travel/hotels          # playbook unit (child execution), resolved under the execution's pin
        args: { city: "{{ workload.city }}" }
      - name: weather
        tool:                             # an ordered tool list is one unit
          - { name: fetch, kind: http, url: ... }
          - { name: shape, kind: python, code: ... }
  next:
    - step: summarize          # runs once the join policy is met

- step: score_all              # homogeneous fan-out: one unit per item
  spawn:
    each: { in: "{{ candidates }}", iterator: c }
    join: settled
    max_in_flight: 8
    unit:
      tool: { kind: python, code: "...", args: { c: "{{ c }}" } }
```

Rules:

- `spawn.each` is the bounded, joinable replacement for `loop: { spec: { mode: parallel } }`. That loop keeps working;
  §9 makes its `max_in_flight` real behind a flag.
- A unit cannot name a step of the parent playbook. To run a sub-graph concurrently, make it a playbook and use a
  playbook unit.
- `restart`, `timeout_s` and `max_in_flight` may also be set per unit (`restart`, `timeout_s`) or per group.
- **Deferred await (TARGET, stage 6, open question §11):** `spawn.await: later` completes the owner step at spawn time and a
  later step joins with `await: { group: gather }`. Structured-concurrency rule: the execution cannot complete while a
  deferred group is un-awaited; it is cancelled at execution end.
- The validator (server register, CLI load) refuses `spawn:` when the runtime's flag is off, with a named error, the
  same way unsupported kinds are refused today (build plan item 2).

## 5. Cancellation and timeouts (TARGET)

### 5.1 Cancel propagation

Cancel flows down the ownership tree: execution → owner step → group → unit → (child execution → its groups …).
Triggers: policy satisfied (`any`, `race`, `at_least`, fail-fast `all`), group or unit `timeout_s`, owner execution
cancelled or failed.

| Unit state | Distributed | CLI |
|---|---|---|
| Not yet dispatched (held by `max_in_flight`) | dropped from the group's pending set; `coroutine.cancelled` | dropped |
| Command queued | the claim is refused: `claim_command` checks a `coroutine.cancelled` / any cancel spelling for that command (fixes the §2.1 bug for executions too) | n/a |
| Command running on a worker | the worker observes cancel at a **cancel point** and aborts (§5.2) | the tokio task's token fires |
| Child execution (playbook unit) | the server cancels the child by `parent_execution_id`, recursively | the child runner's token fires |

### 5.2 Cancel points (cooperative, worker and tools)

- The worker keeps a per-command `CancellationToken`. A per-worker watcher polls the existing
  `GET /api/executions/{id}/cancellation-check` (extended to per-command) for in-flight commands every
  `NOETL_WORKER_CANCEL_POLL_MS` (default 2000). Push delivery is TARGET (rides the EHDB push transport).
- noetl-tools gets an additive `ExecutionContext.cancel: Option<CancellationToken>`. Cancel points:
  - every tool: `select!` on the token around `execute` (drops the future: in-flight HTTP is aborted client-side);
  - between tasks of an ordered tool list;
  - shell / python: kill the child process (as the existing timeout path does);
  - duckdb / rhai (`spawn_blocking`): no preemption; the result is discarded when it returns, and the slot is held until
    then. Stated as a limit;
  - WASM: the existing epoch interrupt (`plugin.rs:157-170`) gets a second trigger, the token;
  - agent: between turns and between tool calls.
- **Cancel does not undo side effects.** An HTTP POST that reached the remote end stays done. Cancel means "stop waiting
  and stop further work, best effort". Units that must not be half-done use `restart: never` and idempotent tools.
- Bound: a running unit stops within `NOETL_WORKER_CANCEL_POLL_MS` plus the time to its next cancel point. A
  `spawn_blocking` engine has no bound beyond its own timeout.

### 5.3 Timeouts

Effective deadline of a unit = min(unit `timeout_s`, group deadline remaining, the tool's own timeout). Expiry is a
cancel with `reason: timeout`; the unit's status is `timed_out`. The registry starts enforcing `ToolConfig.timeout`
(today unenforced) behind `NOETL_TOOLS_ENFORCE_TIMEOUT`.

Interaction with existing limits (all REAL, unchanged):

- **WASM** `NOETL_WASM_FUEL` (10e9), `NOETL_WASM_TIMEOUT_MS` (30 000), `NOETL_WASM_MAX_MEMORY_MB` (1024) stay per
  invocation. A WASM unit is bounded by whichever trips first. WASM units still serialise per worker process (the
  dispatcher mutex), so `max_in_flight: 8` of WASM units on one 4-slot worker runs one at a time; the resource model
  should say so.
- **Agent** `NOETL_AGENT_MAX_TOOL_CALLS` (32) and `NOETL_AGENT_TOOL_TIMEOUT_SECS` (180) stay per agent step. An agent
  step used as a unit is one coroutine; its internal tool calls are **not** coroutines in this RFC (they stay
  sequential). N agent units means up to N × 32 tool calls; the group `max_in_flight` bounds concurrency, not that total.
  Parallel tool calls inside one turn, drawn from the group's budget, is TARGET (stage 6).
- **`kind: playbook` wait timeout**: on timeout the child is cancelled (today it is left running).

## 6. Concurrency limits and backpressure (TARGET)

Three levels; the smallest wins.

| Level | Distributed | CLI |
|---|---|---|
| Group `max_in_flight` | the orchestrator dispatches at most k units and keeps the rest pending in execution state, dispatching one per unit completion (the sequential-loop mechanism, window k instead of 1) | `tokio::Semaphore(k)` |
| Execution cap `NOETL_COROUTINE_MAX_IN_FLIGHT` (default 16) | counted across all groups of one execution, nested child executions excluded (they have their own) | same, per run |
| Capacity | pool slots (`WORKER_MAX_CONCURRENT` × replicas; prod user pool 8 → 80, system pool 4, per resource-model) — excess queues on the command bus, KEDA scales on lag | one box: the CLI flag `--max-in-flight` (default = available parallelism, capped at 16). No cross-machine fan-out. |

**The owner step never holds a slot while it awaits.** On the distributed runtime the owner step is not a command at
all: the orchestrator emits unit commands and joins on their events. Playbook units report completion to the parent by a
server-side event (§7), not by a polling worker. This removes the deadlock the resource model records for awaited
children and honours the callback rule.

A playbook unit counts once against its parent group even if the child fans out; the child's own groups are capped by
its own limits. The resource model gains a `coroutine` section (owner holds no slot; a tool unit holds one slot for its
run; a playbook unit holds none in the parent) with every figure labelled.

## 7. Mapping per runtime (TARGET)

### 7.1 CLI (`noetl run -r local`)

- Coroutines are tokio tasks in a `JoinSet` under a `Semaphore`, each with a child `CancellationToken` of the run's
  root token. Ctrl-C cancels the root token (today it kills the process).
- This needs the owner step to stop `block_in_place`-ing: the `spawn:` path calls the async tool bridge directly. The
  rest of the runner stays synchronous in stage 4; making the whole runner async is not required.
- Playbook units run a child `PlaybookRunner` on a blocking task with its own token.
- **Limits, honestly:** one process, one machine. No pools, no cross-machine fan-out, no durability: process death loses
  every in-flight unit and the run is not resumable. `restart: replay` is accepted and means "retry the unit in-process
  up to its retry policy"; it cannot survive the process.
- The CLI reuses the same join-policy reducer as the server (§10, stage 1), so policy semantics cannot drift.

### 7.2 server

- Owns group state. A pure reducer in orchestrate-core (so it also runs in the WASM drive) takes group spec + unit
  events and returns: commands to dispatch, units to cancel, and whether the owner step is done.
- New events, all on the parent execution's log: `coroutine.spawned`, `coroutine.completed`, `coroutine.failed`,
  `coroutine.cancelled` (with `reason`), `coroutine.group.joined`. They carry `group`, `unit`, `index`, `attempt`.
- Playbook units: `/api/execute` with `parent_execution_id`, `parent_group`, `parent_unit`. When a child reaches a
  terminal state the server appends `coroutine.completed|failed|cancelled` to the parent and triggers the parent's
  orchestrator (no such child → parent notification exists today).
- Cancel cascade by `parent_execution_id`; claim refusal for cancelled commands and all three cancel spellings.
- Cross-instance (`remote: delegate`, catalog RFC §12): a playbook unit delegated to instance B reports by the existing
  polling path; cancelling across instances is already TARGET there and stays TARGET here.

### 7.3 worker

- A tool unit is an ordinary command: one slot for its run, released when the tool returns or is cancelled. No new slot
  semantics.
- Per-command `CancellationToken`, the cancel watcher (§5.2), and enforcement of the unit deadline the command carries
  (`ToolCommand.timeout`, which the server finally fills).
- `restart: replay` needs the command not to be acked-and-forgotten: the worker keeps a per-command lease heartbeat and
  the server re-dispatches on lease expiry (§8). Until then, worker death fails the unit.

### 7.4 noetl-tools

- Additive `ExecutionContext.cancel`; registry-level `select!` and timeout enforcement (flagged).
- `kind: playbook` cancels its child on wait timeout and, when it is run as a playbook unit by the server, does not
  poll at all.
- No coroutine logic inside tools: tools stay atomic compute blocks.

## 8. Failure model and durability (TARGET)

Partial failure is decided by the join policy (§3.3). Error aggregation: `errors[]` lists each failed unit with its
error kind (`tool_error`, `timeout`, `cancelled`, `worker_lost`, `child_failed`). `any` fails with the full list.

Retries: a unit keeps its tool's existing retry behaviour. `restart` governs only the "worker died" case.

| `restart` | Worker dies mid-unit (distributed) | Process dies (CLI) | Use for |
|---|---|---|---|
| `never` (default) | the unit fails with `worker_lost` once the lease expires; the join policy decides | run lost | side-effecting, non-idempotent units |
| `replay` | the server re-dispatches the unit command (at-least-once), up to `max_attempts` | run lost | idempotent reads, pure compute, `kind: wasm` |

What is durable on the distributed runtime: the group's spec, which units are spawned, and every terminal unit result
are events in the log. An orchestrator restart or a re-drive re-derives the group from events, never re-runs a
completed unit, and dispatches only units that are pending or (with `replay`) lost.

Compare the agent loop today: one command holds the whole loop, nothing resumes, and worker death restarts from turn 1
and re-runs children (`agent_host.rs:30-33`). A `spawn:` group is the opposite shape: each unit is its own durable
record, so the group survives any one worker. Build plan item 8 (orchestrator-driven agent turns) can reuse this
machinery: a turn's tool calls become a group.

Today's gap that `replay` depends on: the worker acks the bus at claim, so there is no redelivery, and the orphan sweep
is off by default. Stage 5 adds the lease.

## 9. Env flags (TARGET; all off by default)

Boolean flags follow the repo convention: armed only by the exact string `true`, read once per process (restart to
change), one `const X_ENV` + `x_enabled()` per flag.

| Flag | Component | Effect when `true` |
|---|---|---|
| `NOETL_COROUTINES` | server | accept `spawn:` at register and execute; run the group reducer. Off: `spawn:` is refused with a named error |
| `NOETL_COROUTINE_MAX_IN_FLIGHT` | server, CLI | numeric, default 16: the per-execution cap (read only when coroutines are on) |
| `NOETL_LOOP_MAX_IN_FLIGHT` | server | `loop.spec.max_in_flight` throttles parallel loops (today parsed, ignored). Separate flag because it changes existing playbooks that set the field |
| `NOETL_CANCEL_CASCADE` | server | cancel cascades to child executions; claims are refused for every cancel spelling and for cancelled units |
| `NOETL_WORKER_COOPERATIVE_CANCEL` | worker | per-command tokens + cancel watcher; enforce `ToolCommand.timeout` |
| `NOETL_WORKER_CANCEL_POLL_MS` | worker | numeric, default 2000 |
| `NOETL_TOOLS_ENFORCE_TIMEOUT` | noetl-tools (via CLI and worker) | registry enforces `ToolConfig.timeout`; `kind: playbook` cancels its child on wait timeout |
| `NOETL_COROUTINE_LEASE` | server, worker | per-command lease and re-dispatch for `restart: replay` |
| `NOETL_LOCAL_COROUTINES` | CLI | run `spawn:` locally (and, separately per §10, make local `next` fan-out concurrent) |

None of these goes into a prod manifest in this work.

## 10. Staged implementation plan

Rules for every stage (same as the build plan): one feature per branch and PR, flag off, unit + local + kind tests, no
prod manifest, flag or deploy change. Code PRs stay **draft** until this RFC is approved.

| Stage | What | Repo(s) | Flag | Risk |
|---|---|---|---|---|
| 0 | This RFC; add a `coroutine` section and the §2 findings to `resource-model.json` | ai-meta, server | none | none |
| 1 | Pure group reducer (spec parse, join policies, window dispatch, cancel set, result shape) in orchestrate-core, wasm-clean, property-tested against a model; schema accepts `spawn:` only under the flag | server (orchestrate-core) | `NOETL_COROUTINES` | low: no runtime path |
| 2 | Cancel correctness, independent of coroutines: claim refusal for all cancel spellings, cascade to children, `kind: playbook` cancels child on timeout | server, tools | `NOETL_CANCEL_CASCADE`, `NOETL_TOOLS_ENFORCE_TIMEOUT` | medium: touches claim |
| 3 | Server `spawn:` with tool units: dispatch, window, join `all`/`settled`, events, result shape, pin inheritance; then playbook units with child → parent completion events (owner holds no slot); `any`/`race`/`at_least` with cancellation of pending and queued losers | server | `NOETL_COROUTINES` | medium–high: orchestrator change |
| 4 | CLI: `spawn:` on tokio (`JoinSet` + `Semaphore` + tokens), Ctrl-C cancel, same reducer; local `loop:` gets real iteration (sequential first) | cli | `NOETL_LOCAL_COROUTINES` | medium |
| 5 | Worker cooperative cancel and deadline; tools `ExecutionContext.cancel`; lease + `restart: replay` | worker, tools, server | `NOETL_WORKER_COOPERATIVE_CANCEL`, `NOETL_COROUTINE_LEASE` | medium–high |
| 6 | `loop.spec.max_in_flight` enforced via the window mechanism; deferred `await:`; agent parallel tool calls within a turn as a group (feeds build plan item 8) | server, worker, tools | `NOETL_LOOP_MAX_IN_FLIGHT`, per feature | medium |

Stages 2 and 4 do not depend on 3 and can run in parallel with it.

**Version-pin invariant (all stages).** A tool unit is a command of the same execution and carries its `catalog_id`.
A playbook unit is a child execution with `parent_execution_id` set, so `get_pin(parent)` (REAL with
`NOETL_CATALOG_PINNING`, `catalog_cas.rs:668-735`) gives it the root's watermark and policy, which it cannot widen.
`@latest` in a unit resolves only under the root's `hot_reload` list, as for any sub-playbook. A `replay` re-dispatch
reuses the original command, never a re-resolved playbook. On the CLI the playbook is read once at start; playbook
units resolve from local files at spawn time, which is **not** pinned today (the CLI has no catalog pin). Stage 4 caches
each resolved child body by digest for the run so a unit spawned twice sees the same body.

## 11. Open questions

1. **Leaf units vs. sub-graph units (the main decision).** This RFC makes a coroutine a leaf: a tool or a child
   playbook. Branch logic stays in the graph and loops-as-goto stays untouched. The cost: running a multi-step branch
   concurrently means a playbook unit, which pays the measured ~9–15 s child-execution hop on prod (resource model,
   `kind: playbook`). The alternative is to let a unit be a sub-graph of the same playbook ("run steps a → b → c as one
   coroutine"). That avoids the hop, but needs branch-scoped variables, a join over graph regions and rules for
   back-edges that leave the region. Recommendation: leaf now; revisit sub-graph units if the hop cost blocks a real
   workload.
2. Should `next` inclusive fan-out + reduce barrier become sugar for a `spawn:` group (one join implementation), or
   stay as is? Today it waits for siblings on failure; `all` is fail-fast.
3. Should the CLI also make existing `next` fan-out concurrent (matching the cluster), or keep it sequential and only run
   `spawn:` concurrently? Concurrent is consistent but changes ordering of side effects in existing local playbooks.
4. Default `restart`: `never` (safe for side effects, fails more often) vs `replay` for `kind: wasm` / pure units.
5. Deferred `await:` (stage 6): worth the extra state, or is "join at the owner step" enough?
6. Where the shared reducer lives so the CLI can use it: orchestrate-core published as a crate the CLI depends on, or a
   small module in noetl-tools (already a dependency of CLI and worker).
