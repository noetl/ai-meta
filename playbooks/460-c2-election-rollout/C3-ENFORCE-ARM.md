# C3 — arming enforce, staged

**NOT RUN.** Waiting on the owner's explicit go against the corrected ~19 s
trade. One combined roll ships the ungate image **and** sets enforce together.

## Why combined

The ungate (noetl/worker#359) makes `ehdb_engine_fence_epoch_advances_total`
readable during the post-restart window. Arming enforce in a separate, later roll
would mean the first enforce restart happens on a build where the gate is still
absent for the first ~90 s — i.e. the one window where the gate matters would be
the one window it cannot be read. Shipping both in one patch costs one writer
roll instead of two and keeps the gate readable from the first second of enforce.

## The corrected trade being accepted

| | before #358 | now |
| :-- | --: | --: |
| election driver starts | +329 s | **+22.9 s** |
| lease acquired | +332 s | **+43.3 s** |
| command-bus ingest accepting | +20.7 s | +24.5 s |
| **refused-write window per restart** | **≈ 311 s (5.2 min)** | **≈ 19 s** |

⚠ `lease + renew + 1 = 21 s` is the bound; 19 s is one measurement consistent
with it, not a guarantee. The margin between "accepting traffic" (+24.5 s) and
"holds a token" (+43.3 s) is what the window *is*; both ends vary.

## P0 — baseline

```bash
PROD=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
D=playbooks/460-c2-election-rollout/baseline
kubectl --context "$PROD" -n noetl get sts noetl-cmdbus-writer -o json > "$D/sts-pre-enforce.json"
jq -r '.spec.template.spec.containers[0].image' "$D/sts-pre-enforce.json" | tee "$D/rollback-enforce.txt"
kubectl --context "$PROD" -n noetl get lease ehdb-shard-00000000 -o yaml > "$D/lease-pre-enforce.yaml"
```

⚠ Record `ehdb_engine_fence_epoch_advances_total` and `stale_refused` **before**
the flip, so "0 refusals after" is measured against a known starting point
rather than assumed to have started at zero.

## P1 — the combined patch ⚠ owner-gated

```bash
IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:<V6.6.2_INDEX_DIGEST>
PATCH='{"spec":{"template":{"spec":{"containers":[{"name":"noetl-worker","image":"'"$IMG"'","env":[{"name":"NOETL_EHDB_FENCING","value":"enforce"}]}]}}}}'
```

⚠⚠ **`env` inside a strategic-merge container patch merges by `name`**, so this
updates `NOETL_EHDB_FENCING` and leaves the other 36 variables alone. Verify that
on the dry-run rather than trusting it — a JSON-merge patch would replace the
whole array and wipe the writer's configuration.

Diff the **whole pod template**, not the two fields:

```bash
kubectl --context "$PROD" -n noetl patch sts noetl-cmdbus-writer \
  --dry-run=server -o json -p "$PATCH" > /tmp/after.json
diff <(jq -S '.spec.template' "$D/sts-pre-enforce.json") <(jq -S '.spec.template' /tmp/after.json)
```

Expect exactly: the image line, and `NOETL_EHDB_FENCING` shadow→enforce. Count
the env entries on both sides and assert they are equal.

## P2 — verification, in order

1. **Convergence**: `generation == observedGeneration`, ready 1/1, restarts 0.
2. ⭐ **The gate is readable from the start.** Scrape within the first 30 s and
   assert the block is present — `ehdb_engine_fence_registered` is `0` or `1`,
   never absent. This is what #359 bought; if it is absent, the ungate did not
   ship and **roll back**.
3. ⭐ **At most one writer accepted**: `ehdb_engine_fence_epoch{bus}` equals the
   Lease's `leaseTransitions`, and `ehdb_engine_fence_epoch_advances_total ≥ 1`.
   A marker that never advanced means the fence holds no token and **cannot
   refuse** — green but inert, the exact failure this whole arc is about.
4. ⭐ **No legitimate writer wrongly fenced**: `stale_refused` stays at its
   pre-flip value while `writes_checked` climbs. ⚠ Both numbers together — a
   flat `stale_refused` beside a flat `writes_checked` means the decorator is
   unreached, not that nothing was refused.
5. **Dispatch**: `claim connect failed` burst stops within ~30 s of the roll, as
   on every previous roll. ⚠ Date the last line; the count alone is a restart
   artefact.
6. Hold ≥ 10 minutes and ≥ one seal interval before calling it good. ⚠ Volume is
   not duration: the seal sweep gives ~1 check/s, so a clean 60 s is ~60 samples
   of one mechanism, not a soak.

## P3 — rollback

```bash
kubectl --context "$PROD" -n noetl set env sts/noetl-cmdbus-writer NOETL_EHDB_FENCING=shadow
# or, to also revert the image:
kubectl --context "$PROD" -n noetl set image sts/noetl-cmdbus-writer \
  noetl-worker="$(cat "$D/rollback-enforce.txt")"
```

Shadow is the safe landing: it keeps every counter and refuses nothing.

⚠⚠ **Rollback does NOT touch the Lease or the `.fencing` marker.** The Lease's
`leaseTransitions` is the monotonic fencing token — the election Role has no
`delete` verb precisely so it cannot be reset — and the on-disk marker is the
high-water epoch. Deleting either would let a superseded epoch be accepted as
fresh on the next arm, which is worse than never having fenced.

## Abort criteria

- `stale_refused` climbing with a single writer — a legitimate writer is being
  refused; roll back immediately.
- The fence block absent after the roll — the gate is unreadable; roll back.
- `epoch_advances` 0 while `writes_checked` climbs — inert fence; roll back to
  shadow and investigate before re-arming.
- Writer restart count ≥ 2 in 10 minutes.
- Dispatch failures continuing past ~60 s.
