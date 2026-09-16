# Open work, and what each is waiting on

Updated 2026-09-16. Four branches are open. **None has been self-merged and none
is rolled to prod.** Two are independently shippable; two are held on a decision
that is not mine.

## Independently mergeable — nothing blocks review

| PR | what | why it is independent |
| :-- | :-- | :-- |
| [noetl/server#441](https://github.com/noetl/server/pull/441) | Postgres as the recovery ladder's final rung — a tier that cannot answer no longer ends recovery | server-only; no tier storage format, no worker change, no config change |
| [noetl/ehdb#360](https://github.com/noetl/ehdb/pull/360) | a truncated TAIL record is skipped and counted; anything else still fails the open | library-only; changes a read posture, adds no dependency, no deployment coupling |

Both are kind-proven or workspace-green with two-sided negative controls. Both
are additive and reversible. They are waiting on review, not on a decision.

## Held on the `cmdbus-writer` pin decision

| branch | what |
| :-- | :-- |
| `noetl/worker` `feat/348-durable-kv-object-shadow-store` | kv/object shadow tiers get a durable store on the writer's PVC + the tier-service read path |
| `noetl/server` `feat/348-kv-object-parity-comparator` | the per-tier parity comparator + its gated endpoint |

**Why held:** the prod rollout requires moving `sts/noetl-cmdbus-writer`, which
runs a deliberately different digest from the worker pools
(`sha256:c13b2957…` vs v5.132.5 `sha256:14759cee…`). `memory/current.md` records
it as held back on purpose and the reason is not written down anywhere I could
find. **Rollout order is load-bearing** — on a writer that predates the change
every shadow append is refused (correctly labelled `append_failed`, not lost
silently, but nothing accumulates).

The code is done and kind-proven; only the deployment is blocked. The documented
rollout sequence is in `kv-object-cutover/PROPOSAL.md` §8.

## Owner decisions, with the artifacts prepared

| decision | artifact |
| :-- | :-- |
| the KV/object primary-serve cutover | `kv-object-cutover/PROPOSAL.md` — recommendation is **do not flip**; prerequisites now built, what remains is this decision, the writer pin, and noetl/ehdb#321 |
| the event-log durability substrate | `substrate/EVENTLOG-DURABILITY.md` — four options costed with rollback stories; **only option D is not cleanly reversible**, and it is the one the architecture points toward |
| the `cmdbus-writer` pin | no artifact; needs the reason it was pinned |

⚠ The two proposals are **the same question in different clothes**: the
event-log tier is `primary` on a single-zone disk, and the kv/object shadow
tiers now sit on that same substrate. Neither cutover question can be settled
until the substrate one is.

## Closed this session

noetl/ai-meta#343 (hydration, shipped + verified in prod), #346 (parity
false alarm, shipped), #284 (batch tier-append, already done — closed with the
measurement), noetl/server#438 (resolve_canonical blind on GCS, shipped),
adiona/frontend#22.
