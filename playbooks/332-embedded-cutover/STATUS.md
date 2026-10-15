# Embedded-EHDB program — status and remaining gates

As of **2026-09-09**. One page: what is proven, what is staged inert, what each
remaining gate needs. Prod is **v3.106.1, healthy, shadow armed**.

## Prod today

| | |
| :-- | :-- |
| server | **v3.106.1**, 1/1, 0 restarts, all workloads Ready |
| embedded engine | **armed, SHADOW only** — appends alongside, serves nothing |
| storage | `/data/ehdb-embedded` on the **ephemeral layer**, 1 GiB limit, ~336 KB used |
| rollback | `set image` to `sha256:f2ab83c0…` (v3.106.0), or `NOETL_EHDB_EMBEDDED=false` |

## ✅ Proven

| claim | evidence |
| :-- | :-- |
| The shadow is **reachable** on prod | `opened=1`, `agreed` climbing on real traffic. Before the hook move it was armed and **never opened** for a full window — and an unreachable shadow reports `agreed=0, diverged=0`, identical to a healthy quiet one. |
| The engine **accepts** the real write set | peak `agreed=1,826`, **`diverged=0`**, `append_failed=0`, including under synthetic load. A part genuinely **sealed**. |
| The shadow does **not** cause load collapse | flag-off control collapsed identically at conc 6/8. The cause was the mirror queue (826 `queue stayed full` WARNs) under `DRAIN_CONCURRENCY=1`. |
| **N>1 ownership + forwarding** | 2 shards in kind agreeing *independently* (each pod's `forwarded_ok` = the other's `forwarded_terminus`), one hop, no loops. |
| **Fail-closed** when the owner is down | 4×503 / 2×200 matching the ownership split, `forward_unavailable=4`, and the `FAILING CLOSED` log. Nothing orphaned processed locally. |
| **PV persistence *and recovery*** | pod deleted; md5 of every file identical; same PV rebound; engine **reopened on pre-existing data**; second round `agreed=40 diverged=0`. |

## 📦 Staged inert (written, never applied)

| artefact | what it is |
| :-- | :-- |
| [ops#303](https://github.com/noetl/ops/pull/303) | StatefulSet + `volumeClaimTemplate`. Dry-run clean; touches no live object. |
| `RUNBOOK-deployment-to-statefulset.md` | Cutover steps, the forced serving gap, rollback. |
| `FLIP-serve-from-embedded.md` | Gate criteria + the `shadow → verify → primary` ladder. |
| `docs/rfc/keda-retarget-embedded-backlog.md` | Replacement autoscaler series; **deliberately no code**. |
| `docs/rfc/foca-adoption-and-embedded-cmdbus.md` | Both remaining subsystems, as plans. |
| [server#419](https://github.com/noetl/server/issues/419) | `DEFAULT_EMBEDDED_DIR`'s comment claims a fail-closed guard that does not exist. |

## 🔴 Remaining gates — what each one needs

| gate | blocked on | risk if rushed |
| :-- | :-- | :-- |
| **StatefulSet cutover** | owner go + a maintenance window | needs a deliberate 30–60 s serving gap: two servers on one DB fork the event chain (`chain_heads` is per-replica) and would double-run the armed sweeps |
| **Serve flip (D1)** | `verify` mode **does not exist yet** | ⚠ the shadow proves **appends**, not **reads**. `diverged=0` today says nothing about whether the engine can answer a query. |
| **KEDA retarget** | the embedded command bus | KEDA reading an **absent** series does not fail — it stops scaling, silently |
| **Foca adoption** | transport + timer driver + D8 append wiring | a membership protocol fails by giving a *plausible wrong answer*; must ship observe-only first |
| **Embedded command bus** | design of a **passive** comparator | a queue cannot be shadowed by counting; a shadow that acks double-delivers |
| **N>1 on prod** | cutover first | validated in kind only |

## The one thing to read if you read nothing else

**The shadow's `diverged=0` is not flip-readiness.** It compares append *counts*
on the write path. The read path has never been exercised. The `verify` rung
exists to produce that missing evidence while Postgres is still answering — and
it needs a positive control, or `diverged=0` will again be indistinguishable
from a comparator that cannot fire.

## Not done tonight, deliberately

- No prod load (the 2026-09-09 run degraded dispatch ~40 min; recovered via a
  scoped clear of 38 synthetic executions, with one **real**
  `system/scheduled_cleanup` correctly excluded).
- No server roll, no serve flip, no gated prod change.
