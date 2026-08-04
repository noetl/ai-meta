# Open-PR triage, 2026-08-04

14 PRs open across the fleet, the oldest 5 weeks. Triaged against **live
`shastaratech-noetl-prod`** rather than against their own descriptions, because
the interesting question for a stale PR is not "is it still correct?" but "did
the cluster get there without it?"

For three of them the answer is yes.

---

## The drift cluster — prod has it, the manifest does not

Direct evidence for [#222](https://github.com/noetl/ai-meta/issues/222).

| PR | opened | state | verified against prod |
| :-- | :-- | :-- | :-- |
| [ops#230](https://github.com/noetl/ops/pull/230) | 2026-06-30 | CLEAN | request `1Gi` / limit `2Gi` — **matches both system pools exactly** |
| [ops#231](https://github.com/noetl/ops/pull/231) | 2026-06-30 | CLEAN | all four `NOETL_STATE_INDEX_*` values — **4/4 match** |
| [ops#229](https://github.com/noetl/ops/pull/229) | 2026-06-30 | **DIRTY** | `cronjob/noetl-state-builder-watchdog` exists, created **2026-07-26** |

None is stale work. In every case the manifest is what is wrong, and merging
changes nothing about running prod.

### The mechanism, in one example

ops#229's component was applied imperatively **a month after** a PR containing
it was already open and mergeable. The imperative path is faster than the review
path, so the manifest falls behind and the PR rots — ops#229 has since gone
`DIRTY` and can no longer be merged as-is.

### Two traps for whoever reconciles

- **ops#229's prod CronJob postdates its branch**, so the script or schedule may
  have been adjusted during the imperative apply. Merging the 2026-06-30 content
  could quietly *revert* a live component. Diff each file against what is
  running, don't assume equality. Prod monitoring is **GMP**, not
  VictoriaMetrics, so that PR's `vmrule-*.yaml` may be dead weight.
- **ops#230's rationale has gone stale even though its values have not.** The
  comment justifies the `1Gi` request with "~748Mi steady"; measured today after
  6h32m uptime both pools sit at **~25Mi**:

  ```
  noetl-worker-system-pool-8474cdfc97-qvnzk          1m   26Mi
  noetl-worker-system-pool-shard1-5b79674cf9-pq458   1m   24Mi
  ```

  #166's bounded index and the EHDB cutover both landed since. **This is not an
  argument for lowering the request in that PR** — 25Mi is an *idle* reading (1m
  CPU on both), and the sizing input is peak under load, which is what 748Mi was
  measuring and what an idle number cannot replace. Merge for the drift; re-derive
  the request separately from a loaded measurement. Worth doing eventually
  because Autopilot bills on requests.

### One value prod has that no PR sets

`NOETL_STATE_INDEX_SWEEP_SECS=30` on the system pool. ops#231 sets the other
four; adding it there beats leaving a fifth undocumented imperative value.

---

## The rest, for completeness

| PR | note |
| :-- | :-- |
| server#298, worker#214, worker#215, ehdb#313, tools#92 | opened this session; see `227-nonconvergence-sweep/RESULT.md` and #209 |
| server#286 | #199 sink-state feed — deliberately HELD, not stale |
| ops#239 | self-labelled `GATED — do not merge until go` |
| ops#225, ops#223, worker#183, cli#75, e2e#88 | not triaged against prod this session |

---

## Method

Every row above was checked with a read-only `kubectl get` against the live
cluster and compared to `gh pr diff`. Nothing was merged — merges are gated to a
human in this session — and nothing on prod was modified.
