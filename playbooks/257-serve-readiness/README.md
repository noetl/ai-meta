# ai-meta#257 — consolidated serve-readiness gate

The capstone for the EHDB event-log go-live. Four pieces were each proven
alone; alone is not the question a flip asks. This composes them onto **one**
pair of built images and runs them **together** at **three** worker replicas.

| piece | branch | what it establishes alone |
| :-- | :-- | :-- |
| cross-store comparator | server#343 / worker#265 | there is an instrument that can compare the tier against the authoritative log at all |
| server-authored mirror | `feat/258-server-authored-mirror` | the tier holds the **full** per-execution set (13 == 13), not the 6 the worker-authored mirror could reach |
| tier-service observability | `feat/260-tier-service-metrics` | the serve path's **server half** emits metrics, pinned so `0` means "no traffic" and not "no metric" |
| tier-query-service read path | `feat/257-pr4-tier-query-service` | at N>1 replicas a `local` read answers from one pod's fragment; `service` resolves every replica to one store |

## The composed branch

`feat/257-serve-readiness` on `noetl/worker` — `feat/257-pr4-tier-query-service`
(`7fd7e42`) with `feat/260-tier-service-metrics` (`dcd0266`) cherry-picked on
top. Those two were **separate lineages off v5.115.3**, so no build before this
one contained both. The cherry-pick auto-merged `src/ehdb/metrics.rs` and
`src/event_bus.rs`; both changes survive in the composed tree (`#260`'s
`pin_tier_service_series` call and PR 4's corrected startup line).

Server needs no composition: `feat/258-server-authored-mirror` (`2206728`)
already carries the comparator, the mirror and PR 4's server half.

## Running it

```bash
./deploy.sh load                    # + positive control that the node got the image
./deploy.sh writer                  # tier service on :9110, store on the writer PVC
./deploy.sh arm service 3 shadow    # 3 replicas, reads resolve through the writer
./gate.sh service                   # the evidence bundle

./deploy.sh mode primary            # THE FLIP — one variable, one workload
./gate.sh primary                   # does 'primary' change what runs?

./deploy.sh tierdown                # kill the tier-service face only
./gate.sh killswitch                # demote-to-incumbent, measured
./deploy.sh tierup                  # and it re-promotes on a real success

./deploy.sh mode shadow             # THE ROLLBACK — the same lever, back
./deploy.sh restore                 # released images, zero EHDB env
```

## Arms

| arm | claim under test |
| :-- | :-- |
| `service` | the tier holds the full authoritative set, every replica agrees, and the observability moves on the right labels while it happens |
| `primary` | flipping the tier makes some code path take a different branch — and the **incumbent** keeps receiving the complete set throughout the primary window |
| `killswitch` | with the tier service dead the tier demotes to the incumbent: it never serves partial data, never produces a false `match`, and never errors the caller |
| `mutated` | the whole bundle fails when it should, in **both** families |

## Why the mutation is composed too

`mutation.patch` applies two compiling defects at once — the silent fall-back
that keeps reporting `tier_query_source: service` (PR 4's) and the dropped
`record_tier_service` call for `append` (#260's). A bundle that only failed on
one of them would be presenting the other family's checks as evidence when they
could not fail.

## What this does not establish

* **It is not a promotion.** No tier is `primary` anywhere outside this kind
  cluster, and nothing here was run against prod.
* **The store is still pod-local RWO behind a single writer.** That is the
  availability posture accepted in `docs/rfc/ehdb-primary-serve-availability.md`,
  not something this gate improves.
* **`tests/gate_fast_probe` writes 13 **or** 19 events** depending on timing —
  it emits a further step after `playbook.completed`. Every count assertion here
  is therefore an equality against a freshly-read authoritative count, never
  against a literal.

## Related

* `RESULTS.md` — the run, and the go/no-go evidence.
* `RUNBOOK.md` — RFC PR 7: the per-tier cutover runbook, rehearsed.
* `playbooks/261-tier-query-service/`, `playbooks/260-tier-service-metrics/`,
  `playbooks/258-full-set-mirror/` — the three single-piece gates this composes.
* `docs/rfc/ehdb-primary-serve-path.md` §3.4 — the cutover shape.
* `docs/rfc/ehdb-primary-serve-availability.md` — open question 2.
