# RFC: the interstate bus — mailboxes for registered runtimes, as events

Status: **draft for review 2026-11-16. Nothing in the TARGET sections is built; no code, manifest or prod change.**
Every claim carries a label (below). No benchmark number is new: each figure is a code constant or a cited
measurement, and everything else is in §12 as an open measurement.
Written 2026-11-16 against `main` of server `ebd3f30d` (v3.165.0), worker `cdb737f7` (v6.19.0), tools `ad03a84`
(v4.7.0), cli v6.4.1, ehdb `210531d` (v0.15.1).

**Companion RFC:** [`firecracker-cells-worker-pool.md`](firecracker-cells-worker-pool.md) (ai-meta#584, PR #585). That
RFC defines the **cell** and its **mailbox** inside one runtime. This RFC does not redefine them; it adds the level
above: a **runtime** has an identity and mailboxes, and messages cross from one runtime's mailbox to another's. The
two share one model (§4). ⚠ Until both PRs merge, the cross-links between them resolve only on their branches.

Owner prompt, verbatim: *"we need to design interstate communication channel between noetl clusters, and daemons and
individual cli executions how to exchange context and pass tasks input output between distributed runtimes. kind of
distributed message bus with mailboxes of registered runtime environments. its related to discovery mechanism and
event sourcing nature of the noetl universe."*

Related:
- [`interop-missing-tools-build-plan.md`](interop-missing-tools-build-plan.md) "Item 9 as built": instance identity,
  signed requests, registration, discovery, the pull inbox. **This RFC builds on item 9; it does not replace it.**
- [`interop-topology-and-ai-mcp-playbooks.md`](interop-topology-and-ai-mcp-playbooks.md): liveness in D8, capability
  in ehgraph `noetl-cluster`, enrollment and the runtime JWT design.
- [`distributed-playbook-catalog.md`](distributed-playbook-catalog.md) §4 and §12: `noetl://<ni-id>/…` references,
  `remote: import | delegate`, the cross-instance pin.
- `latency-reduction-plan.md` Stage 2 / ai-meta#559 (PR #556 branch `docs/rfc-bot-fleets-vs-shared-vm`): push
  completion, `/wait`, parking the awaiting slot.
- [`coroutines.md`](coroutines.md) (ai-meta#554): cancel propagation and `max_in_flight`, which must cross the hop.
- [`decoupled-context-event-chain.md`](decoupled-context-event-chain.md) (ai-meta#115) and
  [`ehdb-layered-platform.md`](ehdb-layered-platform.md) D5: reference-only results and the result URN.
- `ehdb-execution-partitioned-event-store.md` (PR #355, branch `design/ehdb-execution-partitioned-store`): strong
  ordering only inside an `execution_id` partition, eventual consistency across replicas and regions.
- [`ehdb-topology-membership.md`](ehdb-topology-membership.md): D8 `RuntimeDataset`, foca.
- Rules: [`execution-model.md`](../../agents/rules/execution-model.md) (callback rule, secrets rule),
  [`data-access-boundary.md`](../../agents/rules/data-access-boundary.md),
  [`self-sufficiency.md`](../../agents/rules/self-sufficiency.md),
  [`representation-drift.md`](../../agents/rules/representation-drift.md).

**Labels**
- **REAL**: on `main` today, cited.
- **REAL (PR)**: code in an open, unmerged PR, behind a flag.
- **DEPLOYED**: on prod, from a cited source.
- **TARGET**: proposed here.
- **NOT_YET_MEASURED**: a real question with no number. None is invented.

---

## 0. Summary

1. **Most of the bus already exists, in four pieces that do not share a model.** Item 9 has identity, signed requests,
   a registry with TTL leases, discovery and a pull inbox (REAL). §12 has cross-instance delegate, which polls every 2 s
   (REAL). #559 has push completion inside a cluster (REAL, flagged). ehgraph has the instance graph, written on prod
   (DEPLOYED). Each has its own envelope, its own state and its own retry rules.
2. **The gap the owner names is real, and it is the event log.** The item-9 task board is in memory, soft state, and
   emits nothing into `noetl.event` (REAL: no emit call in `server/src/instances/`). A §12 delegated call leaves only
   the parent's `call.done` and a `noetl.catalog_remote_call` row (§12.5). A CLI local run has `execution_id: 0` and no
   durable identity (REAL, `cli/src/playbook_runner.rs:831, 1219`). Cross-runtime handoffs cannot be replayed or
   audited today.
3. **Proposal.** One envelope (`interstate/v1`), one address grammar that composes as runtime → cell → mailbox, and
   mailboxes that **are** EHDB event subjects, so a mailbox's state is a projection and every send, accept, reply and
   cancel is an event in the logs of both parties. Delivery is at least once with idempotency keys; payloads go by
   digest-verified reference. Request and response parks the sender's slot (#559 2b), so waiting is free.
4. **Lee's rule from the cells RFC, one level up.** A sender addresses another runtime's **capability mailbox**, never
   one of its cells. The receiving runtime places the work on its own cells. Cross-runtime cell addressing does not
   exist by design.
5. **Trust is deny-by-default and already partly built**: the empty allowlist on prod admits nobody (DEPLOYED), and
   authority never widens across a hop (REAL rule in `instances/tasks.rs`). A laptop CLI is an enrolled, scoped,
   short-lease runtime that never receives credentials and can fetch only the references addressed to it.

---

## 1. Problem

### 1.1 Three runtimes, no shared channel

| Runtime | What it is (REAL) | Identity | Durable event log | Can receive work from another runtime |
|---|---|---|---|---|
| **CLI local** `noetl run -r local` | synchronous engine in one process | none: `execution_id: 0` | events go to `StdoutEventSink` (`executor/src/events.rs:20`); a Feather event buffer exists per local execution (`cli/src/local_buffer.rs`, `~/.noetl/local/<id>/`), and whether `noetl run` writes to it is not verified here | no: a remote reference is refused by name (cli 6.4.0, §12.3) |
| **daemon** `noetl subscribe` / `noetl serve` | long-lived CLI process; `RuntimeKind::Daemon` / `Cli` | ML-DSA-87 instance key, `ni-<32 hex>` (`server/src/instances/identity.rs`) | as CLI | yes, via item 9: it long-polls its inbox (`POST /api/instances/inbox`) |
| **distributed** gateway → server → KEDA pools → EHDB | `RuntimeKind::Distributed` | instance key via `NOETL_CATALOG_PEER_KEY_FILE` | `noetl.event` + EHDB event bus | yes: item 9 inbox (CLI/daemon targets only today) and §12 `catalog.execute` (server targets) |

### 1.2 Four channels that each solve part of it

| Channel | Carries | Delivery | State | In the event log |
|---|---|---|---|---|
| item 9 task handoff (`/api/instances/tasks/{submit,inbox,result,status}`) | playbook ref (path + optional sha256) + inline payload ≤ 128 KiB; result ≤ 1 MiB (`tasks.rs` `MAX_PAYLOAD_BYTES`, `MAX_RESULT_BYTES`) | leased claim (visibility 5 min), redelivery, stale result ignored | in-memory board; restart loses queued tasks (REAL); Postgres write-through in server#567 (REAL (PR)) | **no** |
| §12 delegate (`catalog.execute` / `catalog.execution`) | exact digest + args | A polls B every 2 s with a signed request per poll (REAL) | `noetl.catalog_remote_call`, remote pins | parent `call.done` only |
| #559 push completion | in-cluster child → parent | `/wait` long-poll; park behind `NOETL_PLAYBOOK_AWAIT_PARK` (REAL) | the execution's own events | yes, in-cluster only |
| item 9 push (`reach: push`) | same as the board | push bearer; a failed push falls back to the inbox | REAL (PR) server#569, cli#106 | no |

### 1.3 Three registries and three `RuntimeKind` enums

| Registry | Enum | Values (REAL) |
|---|---|---|
| item 9 instance registry (`server/src/instances/registry.rs:33`) | `RuntimeKind` | `cli`, `daemon`, `distributed` |
| `noetl.runtime` (`server/src/services/runtime.rs:15`) | `RuntimeKind` | `worker_pool`, `server_api`, `broker` |
| D8 `RuntimeDataset` (`ehdb/crates/ehdb-l0/src/runtime.rs:54`) | `RuntimeKind` | `server`, `gateway`, `ehdb`, `worker` (default) |

Each answers a different question, which is fine. But three enums with the same name and overlapping meanings are a
representation that will drift. §5.1 assigns each one a scope.

### 1.4 What is missing, precisely

- A **replayable record** of every cross-runtime handoff on both sides (§1.2 column 5).
- An **execution context** that travels with a task: the pin, the principal, the trace, the deadline and the budget.
  Today item 9 sends a playbook ref and a payload, and §12 sends a digest and args.
- **Idempotency.** A resubmitted item-9 task is a new task; nothing dedups a retry by the sender.
- **References across runtimes.** The result URN `noetl://<tenant>/<project>/results/<eid>/…`
  (`worker/src/result_locator.rs:110`) carries no runtime identity, so it cannot be resolved outside its own cluster,
  and a CLI's results are local files.
- **Waiting that does not hold a slot** across runtimes (§12's 2 s poll holds the parent step).
- **Cancel across runtimes** (§12.5 TARGET).

### 1.5 Non-goals

- A global total order. Order is strong only inside one execution partition (#355 §2.4).
- A broker service. The bus is a set of mailboxes hosted by the runtimes that already exist.
- Replacing the in-cluster command bus. Inside a runtime, commands keep their subjects and the cells RFC's routing.
- Broadcast or topic fan-out in v1 (Q8).
- Moving credentials between runtimes, ever.

---

## 2. Constraints

- **Event log is the truth.** A handoff that is not an event did not happen as far as replay is concerned.
- **Data access boundary.** Only a server writes `noetl.*` and EHDB subjects. Daemons, CLIs and workers reach mailboxes
  through a server's HTTP API.
- **Outbound only for edge runtimes.** A CLI or daemon needs no inbound connectivity (item 9 design, REAL). Push is an
  optimisation with a fallback to pull.
- **Self-sufficiency.** No external broker, queue or discovery service. EHDB carries the mailboxes; the instance
  registry, D8 and ehgraph are the discovery surfaces already present.
- **Secrets.** Business credentials stay in each runtime's keychain, resolved by alias at execution time. An envelope
  carries aliases, never values.
- **Latency.** In-runtime paths (local drive, fused segments, cell routing) are untouched. The bus is used only when a
  step targets another runtime.

---

## 3. The model (TARGET)

### 3.1 Terms

- A **runtime** is a registered NoETL environment with an instance key: a cluster, a daemon, or a CLI process. Its
  identity is its `ni-` id (REAL).
- A **mailbox** is a named, append-only message stream owned by exactly one runtime and hosted by a server (its own,
  or the home server it registers with).
- A **message** is one `interstate/v1` envelope (§6), appended to a mailbox.
- A **handoff** is a request message plus its terminal response, correlated by `msg_id`.
- A **home server** is the server a CLI or daemon registers with. It hosts that runtime's mailboxes because the runtime
  has no EHDB of its own.

### 3.2 Address grammar

One grammar, extending the `noetl://` forms that already exist:

| Address | Meaning | Status |
|---|---|---|
| `noetl://<ni>/a/b@3#sha256:…` | a playbook in that runtime's catalog | REAL (§3.3 of the catalog RFC) |
| `noetl://<ni>` | a runtime | TARGET |
| `noetl://<ni>/mbx/inbox` | the runtime's task inbox: anything it accepts, chosen by its own policy | TARGET (generalises the item 9 inbox) |
| `noetl://<ni>/mbx/cap/<tier>/<profile>` | a capability mailbox: work needing those capabilities | TARGET |
| `noetl://<ni>/mbx/reply/<execution_id>/<step>` | where responses for a parked step land | TARGET |
| `noetl://<ni>/executions/<execution_id>` | an execution in that runtime | TARGET |
| `noetl://<ni>/results/<tenant>/<project>/<eid>/…` | a result, globally resolvable | TARGET (instance-qualified form of the REAL result URN) |
| `noetl://<ni>/cells/<cell_id>` | a cell (cells RFC §5.3) | **local to `<ni>` only**; never accepted from another runtime |

The authority segment is unambiguous: `is_instance_id` accepts exactly `ni-` plus 32 lowercase hex characters
(`identity.rs`). A tenant segment matching that pattern must be refused at tenant creation (Q1).

### 3.3 How it composes with cells

```
runtime  noetl://ni-A                          runtime  noetl://ni-B
  └─ execution E_A, step s  (parked)              ├─ mbx/inbox ─────────────┐
       └─ mbx/reply/E_A/s ◀──── response ───┐     ├─ mbx/cap/T2/python-3.12 ├─▶ B's server routes to
                                            │     │                         │   commands.<cellpool>.T2.<profile>.>
       request ─────────────────────────────┼────▶┘                         │   (cells RFC §5.2)
                                            │                               ▼
                                            └──── B's execution E_B ◀── a cell on one of B's hosts
```

- Between runtimes: **runtime-level, capability-addressed** mailboxes.
- Inside a runtime: the cells RFC's subjects and its lease-affine `cell.<cell_id>` hint, unchanged.
- The receiving server translates one into the other. A sender cannot name a cell, a pool or a host of another
  runtime. This is the no-addressing rule from the cells RFC §5.2 applied to the level above.

---

## 4. One mailbox model, two levels

The cells RFC defines a cell as (boundary, profile, envelope, mailbox, identity) and a mailbox as a capability subject
plus an affine hint. This RFC uses the same definition at runtime level:

| Property | Cell (cells RFC) | Runtime (this RFC) |
|---|---|---|
| Identity | `cell_id`, `generation`, `host_id`, digests | `ni-` id (ML-DSA-87 key), registration `generation` |
| Capability mailbox | `commands.<cellpool>.<tier>.<profile>.>` | `noetl://<ni>/mbx/cap/<tier>/<profile>` |
| Affine hint | `cell.<cell_id>`, falls back to the capability subject | `mbx/reply/<execution>/<step>`, which is exact, because a reply has exactly one consumer |
| Liveness | the host is the authority | the registry lease (`NOETL_RUNTIME_TTL_SECS`) is the authority |
| Supervisor | cell host | home server (for CLI / daemon) or its own server |
| Discovery | D8 host profile sets | instance registry + ehgraph (§5) |

What is *different* at runtime level, deliberately:

- A runtime mailbox is **durable across restarts** (it is an EHDB subject). A cell mailbox is a bus subject whose
  consumers come and go.
- A runtime mailbox crosses a **trust boundary**, so every message is signed (§9); cell messages stay inside one
  runtime's trust domain.

---

## 5. Registration and discovery (TARGET over REAL)

### 5.1 One registry per question

| Question | Surface | Scope |
|---|---|---|
| Which runtimes exist, are they alive, can I trust them, what do they accept? | **item 9 instance registry** (REAL) | between runtimes; the only registry this bus reads |
| Which in-cluster members (server, gateway, worker, cell host) are alive? | **D8 `RuntimeDataset`** | inside one runtime |
| Legacy worker/server rows | `noetl.runtime` | inside one runtime; retire when D8 serves (topology RFC §6) |
| What is connected to what, for operators and agents? | **ehgraph `noetl-cluster`** (DEPLOYED writer) | read model fed from the registry and events; never authoritative |

The interstate layer reads only the first. That keeps the three `RuntimeKind` enums from having to agree, which is the
only way they will stay correct.

### 5.2 Registration

- REAL: `POST /api/instances/register` is an idempotent register-or-renew of signed `Capabilities` (bounded,
  `deny_unknown_fields`). Lease from `NOETL_RUNTIME_TTL_SECS`; a record is forgotten 10 TTLs after its last heartbeat
  (`registry.rs` `FORGET_AFTER_TTLS`).
- TARGET: `Capabilities` gains one optional, bounded block:

  ```yaml
  interstate:
    v: 1
    mailboxes: [inbox, "cap/T2/python-3.12", "cap/T1/*"]   # what it will accept
    capacity_hint: 6          # free units it is willing to take now; a hint, never a promise
    home: ni-…                # for CLI / daemon: the server hosting its mailboxes
    max_inline_bytes: 131072  # what it accepts inline; defaults to today's MAX_PAYLOAD_BYTES
  ```

  An old server refuses the block (`deny_unknown_fields`), which is the correct failure.

### 5.3 Ephemeral CLI runs

A one-shot `noetl run` does not register today (REAL, interop RFC). Proposed:

- A run that sends interstate messages (it references `noetl://<ni>/…` or targets a runtime) registers with its home
  server under its **instance key** with a run-scoped sub-address `noetl://<ni-cli>/executions/<id>`. Its lease
  is the run's lifetime plus one TTL.
- The CLI gets a real execution id (TARGET): a snowflake-shaped id unique within its `ni`, replacing `0` wherever the
  run is visible outside the process.
- Replies addressed to a CLI that has exited stay in its reply mailbox on the home server until the lease is
  forgotten, then become a `interstate.expired` event and are kept for audit. Whether a CLI can reattach and collect
  them (`noetl run --resume`) is Q4.

### 5.4 Discovery

- REAL: signed `POST /api/instances/discover` filters by tool kind, pool, site, label, playbook glob, runtime kind,
  `accepts_tasks` and liveness.
- TARGET: filter by `interstate.mailboxes` too, so "who accepts `cap/T2/python-3.12` and is live" is one query.
- Catalog-driven discovery stays the catalog RFC's bloom probe (§4); the bus does not add a second one.
- A sender caches a discovery answer only for the remaining lease of the target. A lapsed lease is not a target.

---

## 6. The envelope: `interstate/v1` (TARGET)

Signed with the sender's instance key in the REAL `SignedEnvelope` (ML-DSA-87; purpose, audience, ts, nonce, replay
cache that fails closed). The payload document:

```yaml
v: 1
msg_id: 01JD…                       # ULID, unique per sender
purpose: task.submit                # task.submit | task.result | task.cancel | task.status | context.fetch | ack | nack
shape: request                      # request | response | notify
from: noetl://ni-A/executions/7340…
to:   noetl://ni-B/mbx/cap/T2/python-3.12
reply_to: noetl://ni-A/mbx/reply/7340…/score   # absent for notify
correlation: 01JD…                  # = msg_id of the request, on responses
idempotency_key: sha256(ni-A | root_execution | step | frame | attempt | purpose)
causation: noetl://ni-A/events/<event_id>      # the event in A's log that caused this message
deadline_ms: 1763300000000
context:
  root: noetl://ni-A/executions/7340…
  parent: { execution: noetl://ni-A/executions/7340…, step: score }
  pin: { playbook: "noetl://ni-B/score/batch@4#sha256:…", remote_pin_root: 7340… }   # catalog RFC §12.1
  principal: { tenant: …, bot: … }          # recorded by B; B's policy decides what it may do
  trace: { trace_id: …, span_id: … }
  budget: { tool_calls_left: 20, hops_left: 3 }
  credentials: [ "keychain:openai_default" ]  # aliases B must resolve in ITS keychain; never values
input:
  inline: { … }                              # ≤ the target's max_inline_bytes
  refs:
    - { uri: noetl://ni-A/results/t/p/7340…/load/0/0/1, sha256: …, size: 48211331, media: application/vnd.apache.arrow.file }
```

Rules:

- **Context is declared, not dumped.** Only the fields above travel. The parent's full execution context does not; a
  playbook that needs a value passes it in `input`. This is reference-only state applied across the hop.
- **Budgets only shrink.** `hops_left` decrements per hop and a message at 0 is refused, which also stops A → B → A
  loops (Q7). `deadline_ms` can only be the same or earlier than the parent's.
- **Size.** An ML-DSA-87 signature is 4,627 bytes and the public key 2,592 bytes (REAL). That is ~7 KiB per message
  before content. Whether per-message signatures are acceptable at handoff rates, or a signed session key should
  replace them, is NOT_YET_MEASURED (M3) and Q6.

---

## 7. Delivery semantics (TARGET)

### 7.1 Shapes

| Shape | Sender step | Completes when |
|---|---|---|
| `request` | **parks** and frees its slot (the #559 2b mechanism, `NOETL_PLAYBOOK_AWAIT_PARK`, REAL in-cluster, which today requires `NOETL_STATE_BUILDER=offserver`, ai-meta#570); a continuation command is issued when the response is appended to its reply mailbox | the response arrives, or the deadline passes (`timed_out`) |
| `notify` (fire and forget) | does not park | the target's mailbox has durably accepted the message (`ack`) |

§12's 2 s delegate poll becomes a `request` to B's mailbox with a reply mailbox on A. Item 9's submitter poll becomes
the same. Both pollers remain behind their current flags until the bus replaces them (§10, I5).

### 7.2 At least once, exactly-once effect

- Every hop is **store, then ack**: a message is appended to the receiving mailbox's subject before the sender sees
  `ack`. A sender retries until it sees `ack` or the deadline.
- The receiver **dedups on `idempotency_key`**. The first accepted message starts execution E_B; a duplicate is
  answered with the existing handle (`noetl://ni-B/executions/E_B`) and starts nothing. The dedup record is an event in
  B's log, so it survives restart (today's board does not).
- Claims inside the target keep item 9's rule (REAL): a leased claim with a fresh `claim_id`, redelivery on lapse, and
  a late result from an earlier claim answered `stale` and ignored.
- Responses are idempotent by `correlation`: the first terminal response wins; later ones are recorded as
  `interstate.duplicate` and ignored.

### 7.3 Ordering

- No order is promised between messages, across mailboxes, or across runtimes.
- Inside one mailbox, messages are delivered in append order to the extent a single consumer reads them; consumers
  must not depend on it.
- Inside each execution, the execution partition's order holds as #355 defines it. A handoff is two executions, so its
  order is causal (`causation` links), not sequential.
- If a use case needs ordered delivery between two runtimes, it is Q9, not a default.

### 7.4 Backpressure

- **Receiver caps**: per-mailbox queue cap (REAL default `MAX_QUEUED_PER_TARGET = 256` on today's board) and a
  per-sender cap (TARGET). A full mailbox answers `nack {reason: full, retry_after_ms}`.
- **Sender behaviour**: a parked step does not spin. It re-sends on backoff up to its deadline, holding no slot.
- **Credit hint**: `capacity_hint` in registration lets a sender prefer a target with room. It is a hint, refreshed with
  the lease, never trusted for correctness.
- **Concurrency**: a coroutine group's `max_in_flight` (coroutines §6) counts remote units like local ones.

### 7.5 Large payloads: by reference

- Inline only up to the target's `max_inline_bytes`; the default stays at today's 128 KiB. Above that, `input.refs`.
- A reference is `noetl://<ni>/results/…` plus `sha256` and size. The receiver verifies the digest after fetching and
  refuses on mismatch.
- **Resolution** in order:
  1. a shared object store both sides can read (`gs://`, `s3://`, …; the catalog RFC's ambient-identity rule);
  2. a signed `context.fetch` to the origin runtime, served only for references listed in a message addressed to the
     caller, and only until that message is terminal plus a retention window;
  3. refused.
- **A CLI origin uploads first.** A laptop's results are local files, unreachable by anyone else. Before sending, the
  CLI uploads referenced objects to its home server's result store (outbound) and sends the home-qualified URN.
- **Retention.** An object referenced by a live message must not be pruned on the origin. How long after the terminal
  response it is kept, and who pays for it, is Q5.

### 7.6 Cancel

- `task.cancel` travels on the same channel, correlated to the request. B maps it to its own cancel API and its
  coroutine cascade (coroutines §5.1); on a cell, that is a VM kill (cells RFC §5.4).
- A parent cancel on A sends `task.cancel` for every in-flight handoff the execution owns. Time to stop across a hop is
  NOT_YET_MEASURED (M5).

---

## 8. Event-sourcing fit (TARGET)

### 8.1 Mailboxes are event subjects

- A mailbox is an EHDB event subject on its hosting server: `interstate.mbx.<ni>.<mailbox>`.
- Appending a message, claiming it, acking it and completing it are events on that subject. A mailbox's state (queued,
  claimed, done, expired) is a **projection**, rebuilt by replay. The in-memory board (REAL) becomes a cache of that
  projection.
- server#567's Postgres write-through (`noetl.instance_tasks`) is the interim durable store; the RFC proposes moving it
  to the subject in I4 and asks the owner to confirm (Q2).
- Only the hosting server writes these subjects (data access boundary). A daemon or CLI reads its mailbox through the
  home server's API, as it reads its inbox today.

### 8.2 A cross-runtime handoff, as events

A's step `score` in execution `E_A` hands work to runtime B:

| # | Log | Event | Key fields |
|---|---|---|---|
| 1 | A, `E_A` | `interstate.sent` | `msg_id`, `to`, `purpose`, `idempotency_key`, `input` (inline or refs with digests), `pin` |
| 2 | A, `E_A` | `command.completed` marked `pending_callback` | the REAL #559 2b park: the slot is freed and a park row records (parent execution, step, command); TARGET adds `msg_id` and `reply_to` to it |
| 3 | B, mailbox subject | `interstate.received` | `msg_id`, `from`, `idempotency_key`, `causation` = A's event 1 |
| 4 | B, `E_B` | `playbook.started` | `origin: { runtime: ni-A, execution: E_A, step: score, msg_id }`, the pin |
| 5 | A, `E_A` | `interstate.accepted` | `msg_id`, `remote_execution: noetl://ni-B/executions/E_B` |
| … | B, `E_B` | the ordinary step events, possibly on cells | |
| 6 | B, `E_B` | `interstate.replied` | `correlation`, `status`, `result` (inline or refs with digests) |
| 7 | A, reply mailbox | `interstate.response_received` | `correlation`, `status`, result refs |
| 8 | A, `E_A` | `call.done` emitted by A's server | as the REAL park resume does (`server/src/services/await_park.rs`: `call.done` on a callback-parked step is a resume trigger); carries the `msg_id` and the result refs |

For a CLI or daemon, its home server records events 3, 6 and 7 on the runtime's behalf (`interstate.relayed` marks the
hop).

### 8.3 Replay and audit

- **Replay of `E_A`** reads event 7's result (inline or refs) and never re-sends. A message is sent once per
  `idempotency_key`; a replay that reaches event 1 finds it already recorded.
- **Replay of `E_B`** is self-contained: its inputs are in event 4 and its references are digest-checked.
- **Audit across runtimes** follows `causation` and `origin` links in both directions, like a distributed trace. There
  is no global log and no global order, by design (#355 §2.4).
- **ehgraph** gets `handed_to` / `replied_to` edges from these events (an extension of the DEPLOYED `delegated_to`
  edge), so the runtime and mailbox topology is queryable. It remains a read model; the events are the record.

---

## 9. Security and trust

### 9.1 What already holds (REAL / DEPLOYED)

- Identity is a key, not a name: `ni-` = SHA-256 of the ML-DSA-87 public key. The crate (`ml-dsa =0.1.2`) is not
  independently audited (REAL caveat).
- Signed requests with purpose, audience, timestamp and nonce; the replay cache fails closed.
- Trust is an allowlist, default nobody. On prod `NOETL_INSTANCE_REGISTRY` is on with an empty allowlist, so nobody is
  admitted (DEPLOYED, 2026-11-10).
- Authority never widens across the hop: the target must be live, say `accepts_tasks` and list the playbook path in its
  own globs; the server and the target both enforce it; only the two parties may read a task (`instances/tasks.rs`).
- Enrollment tokens (server#568, cli#106) and the gateway passthrough (gateway#66) are REAL (PR), flagged off.

### 9.2 What the bus adds (TARGET)

- **Per-runtime grants.** An enrolled runtime gets scopes, not blanket trust: `send:<mailbox-glob>@<ni>`,
  `fetch:refs-addressed-to-me`, `recv:<own mailboxes>`. A laptop CLI enrolled against prod might hold only
  `send:noetl://ni-prod/mbx/cap/T1/*` and nothing else.
- **No credential ever crosses.** An envelope names keychain aliases; the target resolves them in its own keychain
  under its own policy, or refuses. A sender cannot cause a target to use a credential the target's policy does not
  grant to that principal for that playbook digest (bot-fleets §7.1.4).
- **The principal is recorded, not trusted.** B records A's stated principal in event 4 and applies B's mapping (which
  tenant, which quotas). A runtime cannot raise its own principal's rights.
- **Fetch is scoped.** `context.fetch` serves only references listed in a message addressed to the caller, while that
  message is live. A CLI cannot read arbitrary results from prod.
- **External ingress is one route.** CLIs and daemons outside the cluster reach a server only through the gateway
  passthrough, which is rate-limited and never exposes operator routes.
- **Laptop key custody.** The seed file is local, `0600`, and revocable through enrollment revoke. A stolen laptop key
  has the scopes of its grant and the life of its lease plus revocation latency (NOT_YET_MEASURED, M6).
- **Sandboxing on the receiving side** is the cells RFC's: work from another runtime defaults to the tier its trust
  policy assigns, which for an external CLI should be at least T1 (Q3).

---

## 10. Phased plan (TARGET; every flag OFF by default)

Same rules as the latency plan: one feature per PR; flag off is byte-identical; kind first; accepted on a
before/after measurement; the validation matrix (10-hop probe, concierge, planner turn, auth/login multi-hop with its
15 s budget) must pass. The two-runtime kind rig from §12 (ops#379: A and B, each with its own DB, writer and pools)
is the test bed for every phase. Nothing reaches prod without the owner.

| Phase | What | Repos | Flag | Depends on | Verify |
|---|---|---|---|---|---|
| **I0** | Measure today's handoff (M1, M2) on the two-runtime rig; write the `RuntimeKind` scope table into each repo's wiki | ai-meta, wikis | none | — | numbers with denominators and dates |
| **I1** | Emit `interstate.*` events for today's item-9 and §12 handoffs, on both sides, with no transport change | server | `NOETL_INTERSTATE_EVENTS` | — | every handoff on the rig has events 1–8; flag off: no new events |
| **I2** | `interstate/v1` envelope on item-9 submit: context block, `idempotency_key`, `causation`, budgets; receiver dedup as an event | server, cli | `NOETL_INTERSTATE_ENVELOPE` | I1 | duplicate submit → one execution; `hops_left = 0` refused |
| **I3** | Instance-qualified result URNs; signed `context.fetch`; CLI uploads before send | server, worker, cli | `NOETL_INTERSTATE_REFS` | I2 | 100 MiB input by reference; digest mismatch refused; unscoped fetch refused |
| **I4** | Mailboxes as EHDB subjects; the board becomes a projection cache; migrate from server#567's table | server, ehdb | `NOETL_INTERSTATE_MAILBOX_STORE=ehdb` | I1; Q2 | restart the server with queued messages: nothing lost; projection rebuilt equals the pre-restart board |
| **I5** | `request` shape parks the sender (#559 2b) with a reply mailbox; §12 delegate and item-9 polling switched to it; `kind: playbook` `runtime:` target | server, tools, worker | `NOETL_INTERSTATE_REPLY_PARK` | I4; #559 2b | a parent awaiting a remote child holds no slot; no 2 s poll term in M2 |
| **I6** | CLI: real execution ids, ephemeral registration, local events mirrored as `interstate.relayed` on the home server | cli, server | CLI `--interstate` | I2 | a laptop run hands off to the rig and its record appears on both sides |
| **I7** | `task.cancel` across runtimes, wired to coroutines cancel | server, tools | `NOETL_INTERSTATE_CANCEL` | I5; coroutines stage 1 | M5 |
| **I8** | Server-to-server mailbox forwarding for distributed ↔ distributed (store and forward; both hops events) | server | `NOETL_INTERSTATE_FORWARD` | I4 | partition A from B mid-handoff, heal, exactly one E_B |
| **I9** | Receiving side routes capability mailboxes onto the cells RFC's subjects | server | `NOETL_INTERSTATE_CELL_ROUTING` | cells RFC F6 | a `cap/T2/…` message lands only on a cell pool |
| **I10** | Prod. Owner decision: enrollment, allowlist entries, gateway passthrough | ops | — | all above | prod-roll smoke (e2e + travel planner + ranch concierge) before and after |

---

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **A fifth channel** instead of one: the bus lands beside item 9, §12 and #559 without replacing their pollers. | I5 switches them over; their old paths stay only behind their existing flags, with a removal issue. |
| R2 | **Event volume**: eight events per handoff on two logs. | Measure in I1 (M4); events are small and refs carry the bytes. |
| R3 | **Dangling references**: an origin prunes an object a live message points to. | Retention pin until terminal + window (Q5); fetch refuses cleanly, and the step fails loudly rather than reading nothing. |
| R4 | **Trust creep**: grants widen over time and a laptop key reaches more than intended. | Scoped grants, short leases, revoke; deny-by-default stays the prod state until the owner adds entries. |
| R5 | **Registry drift**: three `RuntimeKind` enums. | §5.1 scope table, written into each repo's wiki; the bus reads one. |
| R6 | **Signature overhead** on chatty handoffs (~7 KiB per message). | M3; session keys if needed (Q6). |
| R7 | **Clock skew** between a laptop and a cluster breaks `ts` checks and deadlines. | Skew bound is REAL in the gate; deadlines are compared on the receiver's clock and reported back. |
| R8 | **Replay of A re-sending** because event 1 was lost between the append and the send. | Event 1 is appended before the send; the send is retried from the event, under the same `idempotency_key`. |
| R9 | **A quiet failure mode**: a refused or expired message that nobody looks at. | `nack`, `interstate.expired` and `interstate.duplicate` are events with counters pinned at 0 (representation-drift rule on absent series). |

---

## 12. Open questions and measurements

### 12.1 Decisions for the owner

- **Q1.** Result URN grammar: instance-qualify (`noetl://<ni>/results/<tenant>/…`, proposed) or keep the tenant-first
  form and add a resolver hint? Either way, forbid tenant names that match the instance-id pattern.
- **Q2.** Is server#567's Postgres inbox the interim store (proposed) or the permanent one?
- **Q3.** Default tier on the receiving side for work from an external runtime (T1 proposed for CLIs).
- **Q4.** Can an exited CLI reattach and collect replies (`noetl run --resume`), or are late replies audit-only?
- **Q5.** Retention of referenced objects after a handoff ends: how long, and is it charged to the origin or the target?
- **Q6.** Per-message ML-DSA signatures, or a per-lease signed session key?
- **Q7.** Default `hops_left`, and whether A → B → A is refused outright or only bounded.
- **Q8.** Fan-out: is a broadcast or topic mailbox in scope for v2, or always N requests?
- **Q9.** Does any real use case need ordered delivery between two runtimes?
- **Q10.** Does the daemon host mailboxes for one-shot CLI runs on the same machine (a local home), or does every CLI
  use a server as home?

### 12.2 Measurements (NOT_YET_MEASURED; none invented)

| # | Measurement | Where |
|---|---|---|
| M1 | item-9 handoff today: submit → claim → result → submitter sees it, p50 / p95 | two-runtime kind rig |
| M2 | §12 delegate today: added latency per hop, including the 2 s poll | same |
| M3 | envelope size and sign/verify cost per message (ML-DSA-87) | microbenchmark on server and laptop builds |
| M4 | events added per handoff, and their bytes, after I1 | rig |
| M5 | cancel → remote work stopped, across one hop | rig |
| M6 | revocation → a revoked runtime's next accepted message refused | rig |
| M7 | 100 MiB by-reference handoff: fetch time by each resolution path in §7.5 | rig |

---

## 13. Linked issues

- Tracking: [noetl/ai-meta#586](https://github.com/noetl/ai-meta/issues/586).
- Companion: [noetl/ai-meta#584](https://github.com/noetl/ai-meta/issues/584) /
  [`firecracker-cells-worker-pool.md`](firecracker-cells-worker-pool.md).
- Builds on item 9 (server#566 merged; server#567, #568, #569, cli#106, gateway#66 open), catalog RFC §12 (#548),
  #559, #554, #115, PR #355.
