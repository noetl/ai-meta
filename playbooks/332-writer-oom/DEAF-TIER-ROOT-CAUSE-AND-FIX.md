# The tier went deaf: my own OOM fix, and what the fix did and did not restore

## Root cause — permit acquired BEFORE `accept`

The reconnect-burst bound took the in-flight permit **before**
`listener.accept()`, with this reasoning in the code:

> Taking the permit first leaves excess clients in the kernel accept backlog,
> which is where backpressure belongs.

That is wrong in one specific way. Once all permits are held, the loop never
reaches `accept()` **at all**. The kernel still completes the TCP handshake, so
a caller connects successfully and then waits until its own timeout. The service
is **deaf**: indistinguishable from down, shedding nothing, recording nothing.

**Measured in prod, 2026-09-22 08:43Z** — every tier, one probe each:

| tier | store | result |
| :-- | --: | :-- |
| `catalog` | 4.7 MB, **no sealed segment** | `timed out after 2s` |
| `kv` | — | `timed out after 2s` |
| `eventlog` | 1.08 GB sealed | `timed out after 2s` |
| `projection` | 3.3 GB sealed | `timed out after 2s` |

**Uniform failure regardless of store size is queueing, not work.** That single
observation is what separated "the seal made reads slow" from "the service is
not accepting", and it is the reason the seal/index work was not the culprit.

The selfcheck also distinguishes the two states usefully: a **down** service
gives `connect: Connection refused`; a **deaf** one gives `timed out after Ns`.

### The chain it drove

tier deaf → appends dropped (`no_durable_service`) → materializer replay crawled
(**61 s for 15 records**, measured in the startup log) → worker registration
starved past its **hardcoded 30 s** (`control_plane.rs:310`) → process exited 1
→ `noetl-cmdbus-writer-0`, which hosts **both** buses, crash-looped every
~2.5 min → `noetl-state-builder-watchdog` restarted the system pool on each
outage → dispatch fell to **26 issued / 4 started** in 5 minutes.

⚠ Rolling back did not help, and that was the clue: `b38ce1e4` carries the same
ordering (it shipped with the OOM fix in v6.1.3). Both images crash-looped
identically.

## The fix (v6.1.6)

1. **Accept unconditionally; bound the work.** A request that cannot get a permit
   within a shed deadline is answered with an explicit busy error — the rule the
   over-large-reply path already set: a refusal must be **countable**, not lost
   to a timeout that looks like the process being down. Waiting requests are
   themselves bounded at 8x the work cap.
2. **Registration is non-fatal.** A control-plane timeout degrades and logs; the
   heartbeat re-asserts presence. `noetl_worker_registration_total{outcome}` is
   pinned at 0 for both values.
3. **Default cap 4 → 8, baked in**, because when the tier went deaf the env
   change was unavailable and only an image swap was.

### ⚠ Deliberately NOT 64

The owner asked for 64. Measured, 64 **reintroduced the deafness by another
route**: 12 concurrent reads of a 973 MiB segment on 2 CPUs starved the runtime
so the accept-and-shed path itself missed a 2 s budget. The cap's job is memory;
raising it does not help when the bound is what protects the runtime. The guard
now asserts **both** ends of the range.

## Kind gate — 4/4 at a prod-sized store

Saturation costs **zero CPU**: 16 clients connect and send nothing, each sitting
in `read_frame` holding a permit. That isolates the one property under test —
where the permit sits relative to `accept()` — from any CPU or memory effect.
Both arms run at the **same cap (4)**, so the verdict cannot be explained by one
arm having more capacity.

| arm | idle | under saturation |
| :-- | :-- | :-- |
| RED — permit before accept | ok, 0.0 s | **`timed out after 2s`, 0 bytes** |
| GREEN — accept, then permit | ok, 0.0 s | **ok, 0.3 s, busy reply** |

Guards that make it non-vacuous: saturation is **asserted** (holders counted,
16 > cap — an earlier version backgrounded them inside one `sh -c`, they died
with the exec session, RED did not go deaf, and the gate proved nothing), and an
**idle positive control** shows the probe can tell serving from not.

Mutation battery **6/6 CAUGHT** against a **3x-verified-green baseline** — the
first run had a red baseline, which makes every arm read CAUGHT and would have
thrown away the result.

⚠ One arm came from a real defect the tests found: `shed()` wrote its reply then
dropped the socket, racing the FIN against the payload. It appeared as a 1-in-3
flake, and a lost shed reply reads exactly like the deaf failure. `shed()` now
closes gracefully.

## Live result — dispatch restored, tier partially served

| | before (08:29Z) | after v6.1.6 (09:57Z) |
| :-- | :-- | :-- |
| writer restarts | climbing every ~2.5 min | **0**, stable |
| registration | fatal, timed out | **succeeded** 09:55:15Z |
| commands / 5 min | 26 issued, **4** started | 10 issued, **13** started, 14 completed |
| `no_durable_service` | 32 per 10 min | **2** per 5 min |

⚠ **Not fully healthy.** Tier reads still exceed the 2 s budget (14 × 2 s, 4 ×
4 s in 5 min) and the writer sits at **999m CPU** — a pegged core. The remaining
cost is the oversized legacy segments: reads that must open the 1.08 GB eventlog
or 3.3 GB projection segment take seconds each, and with 4 permits throughput
collapses even though the service now accepts and sheds.

Measured earlier: **1.05 GiB in one segment reads in 4.0 s; the same data in
4 × 264 MiB reads in 1.0 s.** Splitting the two legacy segments to the 256 MiB
threshold is byte-preserving (split by line, no record rewritten) and is the
next lever — **owner-gated, not done.**

## ⚠ An instrument trap that invalidated several readings

`ehdb-selfcheck tier-load --read-only` **ignores `--timeout-ms` for the read
path**; the budget comes from `NOETL_EHDB_TIER_SERVICE_TIMEOUT_MS` (2000 in
prod). Passing `--timeout-ms 20000` still returned `timed out after 2s` at
`seconds=2.03`.

So every prod "timed out after 2s" reading means **">2 s"**, not "deaf". The
kind gate is unaffected — it measured answer-versus-no-answer, not latency — but
in prod this probe cannot separate a slow tier from a deaf one. That distinction
has to come from the *uniformity* of failure across tiers of different sizes,
which is how the root cause was found in the first place.

## ⚠⚠ A SECOND root cause, found after the fix shipped: the store blocks the runtime

The accept-order fix is correct and proven, but prod's tier is **still**
unresponsive after it. That is not the same defect surviving — it is a second
one underneath.

**Measured, 2026-09-22 10:13Z:**

- An independent verb on a different code path fails too: `tier-concurrency`
  returns `timed out after 30s`, `scan transport failed`. So the tier genuinely
  does not answer — this is not the `tier-load` probe misleading me.
- The process burns **530 CPU ticks in ~6 s ≈ 0.88 cores**, sustained
  (`/proc/1/stat`, not `kubectl top`).
- Per-thread over 6 s: `tokio-rt-worker` **124** and **51** ticks, plus two
  `ehdb-l0-uploader` threads. There are only **8 threads total**.
- **`spawn_blocking` appears 0 times in `tier_service.rs`.**

Tokio sizes its runtime to available parallelism, and the writer's cpu limit is
**2** — so there are **2 runtime threads**. Every tier store operation, which
replays hundreds of MB of JSONL, runs *directly on those threads*. Four
concurrent permits of CPU-bound replay on two runtime threads starves the
reactor completely: the accept loop, the shed path, the metrics server and the
registration HTTP call all stop running.

That is why the fix helps in kind and not yet in prod. **The kind gate saturated
with zero-CPU holders** — deliberately, to isolate the ordering — so it proves
the ordering and says nothing about CPU-bound work. Prod's segments are 1.08 GB
and 3.3 GB, so the work is very much CPU-bound.

It also explains the earlier "64 made it worse" result exactly: more permits
means more CPU-bound tasks on the same two threads.

**The durable fix is to run tier store operations on `spawn_blocking`** so
replay never occupies a runtime thread. That is a change to the request path and
deserves its own cycle and its own gate — one whose saturation is CPU-bound
rather than zero-CPU, since that is the property under test.

⚠ Note what this means for the instrument: a gate that saturates cheaply cannot
detect a starvation defect, and a gate that saturates expensively cannot isolate
an ordering defect. They are different fixtures for different failures, and
using one to claim the other is how a green gate ships a broken service.

### Live state at 10:16Z (writer up 23 min, rolled 09:53Z)

| | value |
| :-- | :-- |
| writer restarts | **0** (was climbing every ~2.5 min) |
| commands / 10 min | 3 issued, **43 started, 43 completed** — backlog fully drained |
| tier / 10 min | 17 `no_durable_service`, 55 × `timed out after 2s` |
| projector `event_2026_q3_pkey` | **0** |

Dispatch is serving. The tier read path is not yet healthy.

## The third answer: segment SIZE is the binding constraint, proven

The `spawn_blocking` hypothesis was implemented (worker#339) and **tested
against its own prediction, which failed**. Under CPU-bound saturation — 8
concurrent reads of a 973 MiB segment at cpu limit 2 — the service still could
not answer a cost-free request on an empty tier.

`spawn_blocking` moves work off the runtime **threads**. It does not move it off
the **CPU**. Eight concurrent ~1 GB replays saturate two cores whichever pool
runs them.

The controlled experiment that settles it — same image, same 8-way load, same
cpu limit, **only the segment size differs**:

| segment | cost-free probe on an EMPTY tier, under saturation |
| :-- | :-- |
| 973 MiB | `timed out after 2s`, 0 bytes |
| **243 MiB** | **ok, 0.0 s, 108 bytes** |

That is one variable, changed alone, flipping the outcome. **Production's
1.08 GB and 3.3 GB legacy segments are the cause of the remaining failure**, and
at its own 256 MiB seal threshold the tier stays responsive under load that
starves it at ~1 GB.

### Why the earlier fixes were still necessary

Each closed a real defect and each was proven, but none could overcome the
segment size:

| fix | shipped | what it fixed | why prod still failed |
| :-- | :-- | :-- | :-- |
| sealed-segment index | v6.1.4/v6.1.5 | reads skip segments that cannot hold the execution | a read that *does* hit the big segment still replays it |
| accept-then-permit | v6.1.6 | a saturated tier sheds instead of going deaf | shedding needs CPU to run |
| store off the runtime | #339, **not deployed** | replay no longer occupies a runtime thread | the blocking pool does not create CPU |

⚠ **Three gates, three different fixtures, and using the wrong one would have
produced a false green each time**: a cheap fixture proves ordering and cannot
see starvation; an expensive fixture proves starvation and cannot isolate
ordering; and only varying segment size alone identifies the constraint. A gate
is an argument about one variable, and it is only as good as what it holds
fixed.

### The remaining action — owner-gated

**Split the two legacy segments to the 256 MiB threshold.** Byte-preserving: it
is a split by line, no record rewritten, nothing deleted. Measured twice now —
4.0 s → 1.0 s for a single read, and starved → serving under concurrent load.
It still rewrites the durable mirror of an append-only log, so it is the owner's
call.
