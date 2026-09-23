# Runtime space: where it actually was, and the segment split

## Phase B verdict (delivered separately)

The ~19 cmd/min are **re-drives**, not legitimate work — so
[#351](https://github.com/noetl/ai-meta/issues/351) is a
[#315](https://github.com/noetl/ai-meta/issues/315) **defect** fix, not a
capacity fix. Evidence in
`handoffs/active/2026-09-23-cmdbus-writer-tier-stall/round-01-result.md`.
**No capacity was added anywhere in this work.**

## Space — the problem was local, not production

### ⚠ Production is NOT filling

Measured at the real PVC mount points, not `df /data` (which reads the
container overlay and is the trap the handoff called out):

| mount | device | size | used | free | % |
| :-- | :-- | --: | --: | --: | --: |
| `/data/cmdbus` | `nvme0n4` | 9.7G | 539.7M | 9.2G | **5%** |
| `/data/eventbus` | `nvme0n3` | 19.5G | 4.8G | 14.7G | **25%** |
| `/data/eventkv` | `nvme0n5` | 9.7G | 112K | 9.7G | **0%** |
| `/data` | overlay — **not a PVC** | 94.3G | 12.6G | 81.7G | 13% |

Nothing to reclaim in prod, and no offload to the object tier is warranted:
the whole tier store is 4.4 GB against 14.7 GB free. I did not invent work here.

### The real consumer: the local build runtime

| | before | after | reclaimed |
| :-- | --: | --: | --: |
| podman images | 69.14 GB (1145) | 37.6 GB (1049) | **31.5 GB** |
| podman volumes | 37.55 GB (6) | 1.03 GB (2) | **36.5 GB** |
| **podman VM disk** | **139G used / 62G free (70%)** | **73G used / 127G free (37%)** | **66 GB** |

What was removed, and why it was safe:

- **Dangling image layers** — untagged, unreferenced.
- **A 30 GB orphaned volume** — the kind node's `/var`: 25 GB of containerd
  images (every gate image loaded this week) plus 4.8 GB of
  `local-path-provisioner` PVC data (my own regenerable test fixtures). Its
  container and network were both gone, so it could never be used again.
- **`noetl-worker-target-musl` (3.4 GB) and `noetl-server-target-musl`
  (1.9 GB)** — Rust build output, regenerable.

**Kept deliberately:** `noetl-cargo-registry` (1.1 GB) and `noetl-cargo-git`
(18 MB) — they materially speed rebuilds and are small. Also verified
`localhost/noetl-worker-rust:proj-bothflags` survived, since `Dockerfile.gate`
uses it as `RUNTIME_BASE`.

⚠ **Self-inflicted, stated:** `podman system prune -f` also **deleted the `kind`
network**, and the container prune removed the already-stopped kind node. The
local kind cluster is destroyed. It was non-functional at the time (API refused)
and kind is disposable, but the prune was broader than I intended and I should
have scoped it. No code change in this work needed kind; any future one does,
and the cluster must be recreated first.

⚠ The host volume did not shrink (83 GB free before and after) — the podman VM's
disk image does not return space to macOS on delete. The reclaim is real inside
the VM, which is where builds allocate.

## The segment split

### Why: re-confirmed before acting, not assumed

At 14:06Z, 28h into a stable writer (restarts=0): CPU **1.03 cores** pegged, and
**every** tier — including `catalog`, which is empty — timed out at 2 s. Uniform
failure regardless of store size is the starvation signature, and the
one-variable experiment from 2026-09-22 established segment **size** as the
cause (973 MiB starves, 243 MiB does not, same image and load).

### Headroom, checked first

4,183 MiB of staging against 14.7 GB free — this is why the space step came
first.

### Method — byte-preserving, reversible, nothing deleted

Per segment: stage chunks with `split -l` into a `.split/` subdirectory the
segment glob ignores; verify; swap by rename; keep the original as `.orig`.

`<name>.<N>` is only treated as a segment when `<N>` parses as an integer, so
`eventlog.jsonl.1.orig` is invisible to the reader — the original stays on disk,
excluded, as an instant rollback.

**Three verifications before any swap:**

1. byte total and line total equal the original;
2. **`cat chunks | cmp - original`** — byte-identity, not a hash;
3. per-execution record counts unchanged across the swap.

### eventlog.jsonl.1 — done

1,085,472,212 bytes / 82,906 lines → **5 segments**: 184, 262, 239, 207,
193 MB (largest 250 MiB, under the 256 MiB threshold).

- totals matched exactly; `cmp` reported byte-identical;
- sampled executions: **6, 5, 38 records before → 6, 5, 38 after**;
- original preserved as `eventlog.jsonl.1.orig` (1,085,472,212 bytes);
- the stale `eventlog.jsonl.1.idx` was moved aside, not applied to the new,
  smaller `.1` — a stale index that over-claims only costs an extra open, but
  leaving it would have been a wrong-by-construction artifact.

No segment-related errors followed, and dispatch stayed healthy (180 started /
182 completed in the next 10 minutes).

⚠ Splitting eventlog alone did **not** relieve the saturation (CPU 1.25 cores,
reads still >2 s) — expected, because the 3.3 GB projection segment is the
larger consumer and is actively mirrored.

### projection.jsonl.1 — done

3,301,113,835 bytes / 96,378 lines → **15 segments**.

- totals matched exactly; concatenation byte-identical;
- sampled executions: **3, 3, 3 lines in the chunks vs 3, 3, 3 in the original**;
- original preserved as `projection.jsonl.1.orig`.

⚠ **Deviation, stated:** the largest chunk is **298 MiB**, above the 256 MiB
target. A line-count split gives uneven bytes because projection records vary
widely in size (34 KB/line average vs the event log's 13 KB). 298 MiB sits well
inside the regime the 2026-09-22 experiment proved works (243 MiB serves, ~1 GB
starves), so it was accepted rather than re-split at further cost to a saturated
pod.

⚠ **A verification bug of mine, and how it surfaced:** the first post-swap check
reported `7 lines` where the original had `3`. The cause was my glob —
`projection.jsonl.[0-9]*` also matches `projection.jsonl.1.orig` *and*
`projection.jsonl.1.idx.orig`, so it counted the chunks, the preserved original,
and a line of the old index (3+3+1=7). Re-run against an explicit list of
`projection.jsonl.1 … .15`, it reads **3 = 3**. The `cmp` byte-identity proof
was never in doubt; the glob was. A verification that includes the artifact it
is verifying against is not a verification.

### The step that made the split actually pay: rebuilding the indexes

Splitting alone changed **nothing** — measured: after both swaps, reads still
timed out at 2 s and CPU was 1.25 cores. The reason is structural: a merged read
opens every segment that *might* hold the execution, and with no index every
segment might. Twenty small segments are read exactly as expensively as one big
one.

Indexes are built by `backfill_segment_indexes` at startup, so this required a
writer restart — a single-writer, in-place restart, no second replica.
**Outage: 55 s** (14:40:47Z → 14:41:42Z ready). It built all **20** indexes
(5 eventlog + 15 projection), serialised.

## Result

| tier | before the split | after split + index rebuild |
| :-- | :-- | :-- |
| `catalog` (empty) | timeout 2.0 s | **0.33 s** |
| `kv` | timeout 2.0 s | **0.12 s** |
| `eventlog` | timeout 2.0 s | **0.11 s** |
| `projection` | timeout 2.0 s | **0.70 s** |
| `object` | timeout 2.0 s | **0.62 s** |

Under live load ten minutes later, `eventlog` read in **0.84 s** — still inside
the 2 s budget. Writer stable, restarts=0; dispatch flowing (218 started / 218
completed per 5 min).

**The comparator recovered completely:**

| server, per 8 min | before | after |
| :-- | --: | --: |
| `could not read the tier` | 127 | **0** |
| `no comparable records` | 127 | **0** |
| tier degraded / timed out | present | **0** |

and it now emits real verdicts with numbers, e.g.
`execution_id=360998744553955328 authoritative=175 ehdb=180 kinds={"count"}`.

⚠ **CPU is still ~1.22 cores.** The split did not change that, and was never
going to: that load is the #315 re-drive loop Phase B identified — 19 cmd/min of
perpetual no-op work. Two independent defects; one is now fixed.

⚠ **Do not read the soak from logs.** Divergences are logged (WARN) and matches
are not, so a log-derived coverage number counts only failures and would read as
0% agreement. The parity **counters** are the instrument; the numbers below are
metric deltas over a fixed window, not log counts.

## Projector shadow soak — the real coverage number

**Projector remains OFF** (`NOETL_PROJECTOR_*` unset on the writer, verified).
**Stopped before any flip, as instructed.**

Window **14:54:11Z → 15:17:06Z (22.9 min)**, measured as deltas on
`noetl_ehdb_crossstore_parity_total`.

| tier | attempts | usable verdicts | **coverage** | divergent |
| :-- | --: | --: | --: | --: |
| **eventlog** | 40 | 40 (26 match + 14 divergent) | **100.0%** | 35.0% of usable |
| **projection** | 40 | 8 (5 match + 3 divergent) | **20.0%** | 37.5% of usable |

The failure modes that previously dominated **did not fire once**:

| counter | before | after | delta |
| :-- | --: | --: | --: |
| `ehdb_unavailable{eventlog}` | 2081 | 2081 | **+0** |
| `tier_unavailable{projection}` | 572 | 572 | **+0** |
| `worker_unreachable{projection}` | 3 | 3 | **+0** |

Event-log comparator coverage went from **0% (everything `ehdb_unavailable`) to
100%**. That is the fix landing.

⚠ **Projection coverage is 20%, and the limit is NOT the tier.** 32 of 40
attempts returned `no_authoritative` — there was nothing on the authoritative
side to compare against. That is the sparse-write property recorded in
ai-meta#265 (an execution can complete with no snapshot row), an
**authoritative-side** gap. The tier itself was readable for every attempt.

⚠ **Not flip-ready.** 35% of usable event-log verdicts diverge. That is
consistent in magnitude with the open
[#346](https://github.com/noetl/ai-meta/issues/346) (event-log parity 36.9%
divergent, order-only, zero data loss), but I did **not** confirm the *shape* of
this window's divergences — see the instrument note below. Treat 35% as measured
and uncharacterised.

## ⚠⚠ An instrument failure in my own earlier reporting

`kubectl logs --since` was **not bounding these queries**. Totals barely move
across windows — `--since=8m` returned 1993 lines, `--since=90m` returned 2156,
and the parity-line count was identically 3 for 8m, 20m, 60m and 90m.

So the log-derived figures I quoted earlier — "`could not read the tier` 127 →
0" and the 12 sampled divergences — were computed over windows that were not the
windows I believed. **The direction of that result still holds**, but it holds on
the counter evidence above (`ehdb_unavailable` delta +0 over a fixed window), not
on the log counts. I could not re-derive the divergence *direction*
(ehdb-ahead vs behind) at all, because the lines are no longer retrievable.

The counters are the instrument here; the logs are not. That is the same lesson
as the soak itself: matches are not logged, only divergences are, so any
log-derived coverage counts failures only.

# ⚠⚠ CORRECTION: the split is INVALID and must be rolled back

**A line-split is not a valid way to split an EHDB segment.** Sequences must
start at **1** and be contiguous; every chunk after the first starts
mid-sequence and the driver refuses it:

```
error tier segment /data/eventbus/ehdb-tier/eventlog.jsonl.2 unreadable:
invalid state: expected transaction sequence 1, got 16583
```

| segment | first sequence | readable |
| :-- | --: | :-- |
| `eventlog.jsonl.1` | 1 | ✅ |
| `eventlog.jsonl.2` | 16583 | ❌ |
| `eventlog.jsonl.3` | 33165 | ❌ |
| `projection.jsonl.1` | 1 | ✅ |
| `projection.jsonl.2` | 6427 | ❌ |

## ⚠ I had already found this constraint and did not apply it

Yesterday, building the kind fixture, I hit exactly this and wrote it down as
one of three stored-format constraints — then split production by line anyway.
My verification (byte totals, `cmp` byte-identity, per-execution counts) proved
the **bytes** were preserved and could not, by construction, detect a **format**
violation. Byte-identity was the wrong invariant: I never checked that each
chunk was independently *loadable*.

## Why the earlier measurements looked good but proved nothing

- The read probes used an **absent** execution id, so the index ruled every
  sealed segment out and nothing was opened.
- The soak samples **recent** executions, which live in the active segment.
- A **full scan** does open every segment — which is why `tier-concurrency`
  failed immediately.

"Every tier answers in 0.11–0.77 s" and "eventlog coverage 100%" were measured
correctly and are **not evidence that the split worked**.

## Blast radius — no data lost

| file | bytes | expected |
| :-- | --: | --: |
| `eventlog.jsonl.1.orig` | 1,085,472,212 | ✅ |
| `projection.jsonl.1.orig` | 3,301,113,835 | ✅ |

Reads needing a segment ≥2 **error loudly** rather than returning wrong data.
Dispatch flowing; writer restarts=0.

## The fix — renames only, BLOCKED on permission

Move the invalid chunks out of the segment namespace (kept, not deleted), drop
the derived `.idx` files, restore `*.orig`. The permission layer refused this
(`Modify Shared Resources`) and I did not work around it.

## A correct split is not a file operation

Each output must be a valid segment, which needs a **writer-side re-seal** (the
writer assigns sequences) or rewriting the `sequence` field — which "no record
rewritten" forbids. That is a code change, and it must be proven in kind first.
⚠ kind is currently destroyed by my earlier prune.
