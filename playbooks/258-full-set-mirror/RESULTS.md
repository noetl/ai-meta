# #258 gate — results

Kind, `kind-noetl`, on **built images** (`localhost/noetl-server:258full`,
`localhost/noetl-worker:258full`), never a local `cargo run`. Probe:
`tests/gate_fast_probe` v76, one worker replica.

## The headline

| arm | authoritative | mirror-expected | `unmirrored_by_design` | tier | matched | divergences | verdict |
| :-- | --: | --: | --: | --: | --: | --: | :-- |
| **server** | **13** | **13** | **0** | **13** | **13** | **0** | `match`, 21/0 |
| worker (flag off) | 12 | 6 | 6 | 6 | 6 | 0 | `match`, 17/0 |
| mutated | 13 | 13 | 0 | **11** | 11 | **2** | `divergent`, 15/0 |
| server (restored) | 13 | 13 | 0 | 13 | 13 | 0 | `match`, 21/0 |

**13 == 13.** The event-log tier holds the complete authoritative event set for a
healthy execution, where before it held 6.

## Two-sided — the arms discriminate

The flag-off arm reproduces the pre-change behaviour on the same images:
`unmirrored_by_design = 6`, tier holds **6 of 12**, and
`noetl_ehdb_eventlog_mirror_total{outcome="mirrored"} = 0` — the server mirrored
nothing. So the full-set match in the `server` arm is attributable to the flag
and not to the images, the probe, or the cluster.

That the server's counter reads 21 (arm 1) / 13 (restored) and **0** with the
flag off is what rules out the other explanation for a clean match: that the
tier was filled by something else and the comparator merely agreed with it.

## The mutation check

Mutation, in `mirror_rows`, compiling:

```rust
.filter(|r| r.event_type != "command.issued")
```

Chosen because `command.issued` is server-authored (so it is in the tier *only*
because of this change), is neither the first nor the last event (so its absence
cannot be mistaken for a truncated or empty tier), and occurs more than once per
execution (so the miss is not a single-record edge case).

Result — the comparator caught it, with the right kind:

```
outcome: "divergent"    holds: false
count          authoritative(mirror-expected)=13 ehdb=11 (authoritative total 13)
missing_event  2 mirror-expected authoritative event(s) absent from the tier:
               [345799157153271808, 345799168234622976]
```

Reverting the mutation returned the same cluster to `match`, 13/13, 21/0.

### The controls stayed green, and that is the correct result

`controls_ok=true, expected=8, unexpected=0` before **and** after every arm,
including the mutated one. That is not a missed detection: the in-binary controls
test **the comparator**, and this mutation is in **the mirror**. The comparator
was untouched and fully working — which is exactly what makes its `missing_event`
verdict trustworthy. Had the controls flipped here, the mutation would have
broken the comparator too and the verdict would be worth nothing.

Controls flipping is what a *comparator-side* mutation produces; that was
demonstrated separately in server#343's own gate (Arm F: removing one membership
check → `unexpected=2`, self-test → HTTP 500).

## Two harness defects the gate found in itself

**1. `jq -e` treats a literal `false` as failure.** The `field()` helper used
`jq -e -r`, whose exit status is non-zero when the last output is `false` or
`null`. So `holds: false` — the single most important value on a divergent
verdict — read as `__ABSENT__`, and the mutation arm reported `14 passed, 1
failed` while the server's body plainly said `"holds":false`. Fixed by dropping
`-e` and testing for the string `null`, which separates absent / false / broken
query. Worth noting the failure mode was **loud**: it reported a FAIL rather than
silently coercing to a pass.

**2. A settling cluster produces a passing but vacuous control.** The first
flag-off run compared **0 of 2** events — the pods were still rolling — and every
assertion in that arm passed, because "tier holds a strict subset" is trivially
true of 0 of 2. Re-run on a settled cluster it gave the honest 6 of 12. Nothing
in the arm was wrong; it just was not discriminating. The `authoritative total is
a real execution (>= 10 events)` assertion exists in the `server` arm for this
reason, and the same guard belongs in the `worker` arm.

## An operational trap worth carrying forward

**A KEDA ScaledObject with `autoscaling.keda.sh/paused-replicas: "0"` silently
reverts `kubectl scale`, and a 0-replica Deployment reports "successfully rolled
out".** The arm therefore looked armed with no worker pod in existence, and
`kubectl rollout status` said so cheerfully. Caught by checking
`get endpoints noetl-worker-rust-metrics` — `<none>` — rather than trusting the
rollout. Pinned to `1` for the gate; restored afterwards.

This is the same shape as the `paused` ScaledObject note already in memory (a
paused SO deletes the HPA and makes `.status` meaningless): a paused KEDA object
is an authority that keeps acting while looking inert.

## What this does NOT establish

Stated rather than implied, because a later reader will want to flip a tier on
the strength of this page:

* **This is not a promotion.** No tier was set to `primary`. The tier now holds
  the whole set; whether it can *serve* it is a separate question (#257 §3.4),
  and the store is still pod-local and RWO.
* **One replica, one relay.** The tier is coherent here because the server sends
  every append to one endpoint. Under `server` mode that is structural rather
  than a replica-count accident — but the store itself is still not shared.
* **A theoretical ordering window remains.** `emit_events` mirrors just after the
  chain-head critical section rather than inside it, so two concurrent
  `emit_events` calls for one execution could in principle append out of
  `event_id` order. No `order` divergence was observed across any arm. If it
  ever appears, the fix is to move the append inside that section — not to relax
  the comparator.
* **The gate worker image is not DuckDB-capable** (`--features
  duckdb-integration` cannot build offline). Sound for this gate, which touches
  no DuckDB path; not sound for one that does.
