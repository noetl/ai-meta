# #258 — closing the event-log tier mirror gap

**Status:** built + kind-validated, default-off, nothing on prod.
**Tracks:** [ai-meta#258](https://github.com/noetl/ai-meta/issues/258),
[ai-meta#257](https://github.com/noetl/ai-meta/issues/257) §3.4.
**Builds on:** [server#343](https://github.com/noetl/server/pull/343) +
[worker#265](https://github.com/noetl/worker/pull/265) — the cross-store
comparator, both still open.

---

## 1. The finding this closes

The comparator that landed with server#343 answered the question it was built
for, and the answer was worse than "the stores disagree":

| authoritative events | carry `meta.worker_id` | actually in the tier |
| --: | --: | --: |
| 13 | 8 | **6** |

Seven of thirteen events have no tier copy **by construction**. The mirror hook
sits on the worker's emit chokepoint (`ControlPlaneClient::emit_event`), and the
server authors the rest itself — `playbook_started`, `command.issued`,
`step.enter`, `playbook.completed`, and `command.claimed` inside the claim
transaction. None of those passes through a worker, so none is mirrorable from
one.

The comparator is right to label them `unmirrored_by_design` rather than
divergence. But that label is precisely the bar on promotion: a tier holding
fewer than half the events cannot be the source of truth for replay, so the
event-log flip in #257 §3.4 could not proceed on a clean parity verdict.

## 2. The design decision

**The mirror moves to the server's write chokepoint. It is not extended.**

The obvious shape — keep the worker mirror and add the server-authored events
beside it — was rejected, and it fails on **ordering**.

The comparator checks that the tier's records sit in the same relative order as
the authoritative log. With two independent producers appending, nothing orders
their appends against each other: the server can assign `event_id` 100 while the
worker's earlier `event_id` 99 is still in flight, and 99 lands second. That is a
real race, neither side can fix it locally, and it would surface as an
intermittent `order` divergence indistinguishable from a genuine one. A parity
mechanism whose own architecture generates false divergence is worse than no
parity mechanism.

So instead the mirror moves to `handlers::event_write::emit_events`, which is
**the one chokepoint every authoritative event passes through** — the worker's
own events included, because a worker event reaches `noetl.event` only by way of
`POST /api/events` → `handle_event` → this same function. Verified rather than
assumed: the gate-on `command.claimed` branch publishes through `emit_event`
after the claim transaction commits, so even the one event written inside a
transaction arrives here.

Four properties fall out of that one placement:

| property | why it holds |
| :-- | :-- |
| **completeness** | the mirror is the code that produces the authoritative set, so the mirrored set *is* that set |
| **ordering** | one producer, appending in the order the per-execution chain head already serialises. No cross-producer race exists to lose |
| **identity** | the server assigns `event_id`; nothing to stamp or reconcile |
| **payload identity** | the projection is built from the row about to become authoritative |

The hook sits **after** terminal dedup and chain stamping and **before** the
publish/insert fork. After, so a suppressed duplicate terminal is not mirrored
and the mirrored record carries the `prev_event_id` the log will carry. Before,
so both branches are covered by one call site — mirroring inside each branch
would be two implementations of one guarantee, and the gate-off branch is the one
prod never exercises, which is exactly where the second copy rots.

### 2.1 The data-access boundary is not crossed

The server owns `noetl.event`, and #257 §3.5 already names the server as the
component that resolves through the tier service when the event-log tier goes
primary. Mirroring from the server is that boundary, not an exception to it.

The control-plane guard is equally intact: **the server does not open tier
storage.** It POSTs to the worker's tier surface — the same
`NOETL_EHDB_WORKER_QUERY_URL` hop it already makes to read.

### 2.2 Why the append shares a route with the read

`POST /ehdb/tiers/{tier}` is deliberately the same route as the GET, and this is
a correctness property rather than a tidiness one. The GET handler resolves which
store answers — this pod's own log, or the writer-fronted tier service — from
`NOETL_EHDB_TIER_QUERY_SOURCE`. A write that resolved its store any other way
could land somewhere the comparator does not read, and the comparator would then
report every server-authored event missing: a total divergence that is an
artefact of two stores rather than a fact about either. One handler makes
"written where it will be read" true by construction instead of by two env vars
agreeing.

### 2.3 A side effect worth naming

#257 §1.3 records that the tier is not one store but N disjoint pod-local ones,
one per worker. Under `server` mode the server is the sole producer and sends
every append to one relay endpoint, so **the fragmentation disappears by
construction** rather than by pinning replica count. That does not by itself make
the tier servable — the store is still pod-local and RWO — but it removes one of
the three obstacles §1.3 lists.

## 3. The switch

One variable, read by both components, so they cannot hold different opinions
about who is mirroring:

`NOETL_EHDB_EVENTLOG_MIRROR_SOURCE` ∈ `worker` (default) | `server`

| | worker mirrors | server mirrors | tier holds | comparator scope |
| :-- | :-- | :-- | :-- | :-- |
| `worker` | yes | no | worker-emitted subset | `meta.worker_id IS NOT NULL AND event_type <> 'command.claimed'` |
| `server` | **no** | yes | the whole authoritative set | every event |

The worker-side **disarm** is not optional. With both halves mirroring, every
worker-emitted event is appended twice and the comparator reports a count
divergence — loud, which is the direction to be wrong in. A silent double-append
would inflate the tier while still matching on membership.

Anything unrecognised resolves to `worker`. A typo must leave the old mirror
running, never disarm both halves and leave the tier silently empty while
`NOETL_EHDB_EVENTLOG` still reads `shadow`.

## 4. Running the gate

```bash
./deploy.sh load
./deploy.sh arm server   && ./gate.sh server
./deploy.sh arm worker   && ./gate.sh worker     # the discriminating half
./deploy.sh restore
```

See `RESULTS.md` for what it measured.
