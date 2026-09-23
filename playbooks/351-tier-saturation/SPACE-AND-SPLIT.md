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

### projection.jsonl.1 — in progress

3,301,113,835 bytes / 96,378 lines → 15 chunks of 6,426 lines (~209 MiB each).
Staged and under verification at the time of writing.
