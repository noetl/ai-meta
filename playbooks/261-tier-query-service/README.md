# ai-meta#257 PR 4 — the tier read resolves to one store

**What this gate proves, in one line:** with more than one worker replica the
EHDB event-log tier is N disjoint pod-local stores, and
`NOETL_EHDB_TIER_QUERY_SOURCE=service` makes every replica answer from the
writer's single durable store instead.

## Why this had to be built before any event-log flip

[#258](https://github.com/noetl/ai-meta/issues/258) closed the mirror gap: the
event-log tier now receives all 13 of an execution's 13 authoritative events,
and the cross-store comparator measures it. That gate ran at **one worker
replica**, deliberately and with the reason stated — the tier store is pod-local
(`NOETL_EHDB_LOCAL_REFERENCE_LOG`), so at N replicas it is N fragments and a
read answers from whichever pod the relay's Service routed to.

That makes the #258 result true and *not sufficient*. Prod runs multiple
replicas. A `13 == 13` read at N replicas is a statement about one pod, and it
arrives in a body shaped exactly like a statement about the tier. Both the serve
path and the parity check are only correct at one replica today.

Two things follow, and this playbook covers both:

1. reads (and appends) must resolve through the writer-fronted tier service;
2. **which store answered has to be visible**, or no gate can tell a working
   service path from a silent fall-back to local.

## What changed

| repo | branch | commit |
| :-- | :-- | :-- |
| `noetl/worker` | `feat/257-pr4-tier-query-service` | `feat(ehdb): tier reads resolve through the writer, observably or not at all` |
| `noetl/server` | `feat/257-pr4-tier-query-service` | `feat(ehdb): the cross-store verdict names the store it compared` |

Both stack on `feat/258-server-authored-mirror`, which stacks on the open PRs
`server#343` / `worker#265`. See `PENDING-PUSH.md`.

The selection itself already existed — `tier_query_source.rs` shipped in worker
`main`, and both the read and the #258 server-authored append already branched
on it. What it lacked was the two properties that make it usable as *evidence*:

**1. The reply names the store.** `tier_query_source` (`local` /
`downgraded_local` / `service`) plus `tier_service_addr`, on every reply from
`GET|POST /ehdb/tiers/{tier}`, and carried up into the comparator's verdict at
`/api/ehdb/parity/executions/{id}`. Absent before, on both arms — so the arms
were indistinguishable from outside the process.

**2. Asking for the service and not getting it fails loud.** The two ways of not
having a service were one silent fall-through:

| state | before | now |
| :-- | :-- | :-- |
| no address at all | local, WARN | unchanged — mid-rollout case; a read path must not start erroring during a deploy |
| an address that cannot be used | local, **silently** | 503 `unavailable`, naming the offending value |

`effective_source` returned `(source, downgraded)` and each call site then did
`if let Some(client) = TierClient::from_env()` with the local read as the next
statement. A typo'd address therefore answered from a store the operator did not
ask for. It is now a `Resolution` variant, so the compiler requires the case to
be handled, and the client is built inside `resolve` from the same `EnvMap` the
source came from — "which source did I ask for" and "which address do I dial"
can no longer come apart.

Also: under `service`, a non-eventlog tier is refused (501 `unsupported_tier`)
rather than answered with event-log records. The remote store backs the event
log only.

Default stays `local`, byte-identical to the pre-change path.

## Topology under test

```
        server                       worker pool (3 replicas)          writer (1)
        ──────                       ────────────────────────          ──────────
  mirror POST ─┐                    ┌─ replica A ─┐                   :9110 tier service
  parity  GET ─┴─ relay :9090 ──────┼─ replica B ─┼── source=local ──▶ its OWN /tmp store
                                    └─ replica C ─┘   source=service ─▶ /data/eventbus/tier
```

`local`: three stores, and the answer depends on routing.
`service`: one store, and it does not.

## The three arms

| arm | setup | must show |
| :-- | :-- | :-- |
| `local` | 3 replicas, `…QUERY_SOURCE=local` | the replicas **disagree**; at least one holds fewer than 13; the comparator's verdict **changes with which replica the relay is pinned at** |
| `service` | 3 replicas, `…QUERY_SOURCE=service` | every replica returns the **same** 13; `match` from every replica; `unmirrored_by_design=0` |
| `mutated` | as `service`, but the tier-service address repointed at a store that does **not** hold the execution | every replica still says `source=service`, **none** returns the local records, and the verdict changes |

The `mutated` arm is the one that proves the service path is really being read.
The pod-local stores are untouched between `service` and `mutated` — only the
address moves. A silent fall-back to local would return the records anyway.

## Running it

```bash
./deploy.sh load                       # both gate images into the kind node (checked)
./deploy.sh writer                     # writer: :9110 + store on the PVC
./deploy.sh arm local 3   && ./gate.sh local
./deploy.sh arm service 3 && ./gate.sh service
./deploy.sh point <empty-tier-host:port> && ./gate.sh mutated
./deploy.sh restore                    # released images, zero EHDB env, pool to 0
```

`gate.sh` pins `NOETL_EHDB_WORKER_QUERY_URL` at one pod IP at a time, so "which
replica answered" is a controlled variable rather than a DNS race. It restores
nothing on its own — `deploy.sh restore` is the cleanup.

## Standing constraints honoured

* No prod change of any kind. No tier promoted to `primary`.
* No `NOETL_EHDB_TIER_*` set on prod.
* Nothing pushed — see `PENDING-PUSH.md`.
* Kind restored to released images with zero EHDB env after the run.

## Related

* [#257](https://github.com/noetl/ai-meta/issues/257) — the RFC. PR 4 in §5,
  cutover in §3.4.
* [#258](https://github.com/noetl/ai-meta/issues/258) — the comparator and the
  full-set mirror this reuses as its instrument.
* [`agents/rules/representation-drift.md`](../../agents/rules/representation-drift.md)
  — a pod-local answer that reads as a tier-wide one is the drift class this
  closes.
