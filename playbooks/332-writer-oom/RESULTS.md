# Writer OOM — root cause, fix, and the kind proof

**2026-09-21.** Two root-cause changes, both kind-proven RED→GREEN. **Not yet
deployed.** Prod still carries only the 8 GiB mitigation from 2026-09-20.

## The root cause, measured

The tier is **not** an L0 engine, so it has none of the part-sealing the command
bus and events feed get from `seal_aged_parts` (both log `seal_max_age_ms=5000`
at startup; the tier logs nothing). It is **one JSONL file** that
`LocalReferenceRuntime::open` replays **in full** into an in-memory
`ReferenceDatabase`, which the reference-runtime cache then holds **for the life
of the process**. And `LocalReferenceRuntime::append` does `self.state.clone()`
**per append**.

Two consequences, both linear in record count. Measured in isolation:

| records | ms/append | on disk | peak RSS |
| --: | --: | --: | --: |
| 400 | 8.12 | 0.7 MB | 8.4 MB |
| 2000 | 20.87 | 3.6 MB | 14.1 MB |
| 4000 | **36.56** | 7.2 MB | 21.2 MB |

A **4.5× rise in per-append cost over a 10× store growth** — O(n) per append,
O(n²) to build. Harness: `memcheck.rs`.

At production scale (a **4.0 GB** store) that is simultaneously the ~3 GiB
baseline, the `"timed out after 4s"` tier appends, and — once a KEDA scale-out
(1→20) put ~20 concurrent appends through an **unbounded** `serve_tier` accept
loop, each copying that state — the OOM that killed the writer at 4 GiB and
again at 8 GiB.

## The two fixes

**1. Tier seal** — `NOETL_EHDB_TIER_SEAL_MAX_BYTES`, **default off**.
Seal by **rename**: `eventlog.jsonl` → `eventlog.jsonl.<n>` beside it, then a
fresh active segment, then `ehdb_reference::forget_runtime` drops the cached
runtime for the old path — *without that the seal bounds the file and not the
process, which is the entire point*.

- Same JSONL format; nothing about the on-disk encoding changes.
- Renames only: never rewrites, never deletes, sealed segments stay on disk.
- The rename **is** the operation — no window exists where a record is in
  neither file.
- **Both** readers merge sealed + active, oldest first, renumbering
  `global_sequence` over the merge. An unreadable segment is an **error**, never
  a silent skip.

**2. Reconnect-burst bound** — `NOETL_EHDB_TIER_MAX_INFLIGHT`, default **4**.
The permit is taken **before** `accept`, so excess clients wait in the kernel
backlog instead of becoming in-flight state copies. Acquiring *after* accept
would bound only how many run at once and leave connections and tasks unbounded
— the same failure in a different hat. A queue would do the same.

## Kind proof — RED reproduces, GREEN survives

`./kind-gate.sh` (RECS=4000 CONC=20 PAD=16384). Both arms: identical image,
identical load, identical `requests 128Mi / limits 192Mi`. **The only difference
is the two env vars.** Reproduced across two consecutive runs.

```
red  : phase=Failed  oom='OOMKilled'  exitCode=137     <- the production signature
green: phase=Running oom=''           restarts=0
```

And the performance difference at a 253 MB store:

| | RED (unsealed) | GREEN (sealed+bounded) |
| :-- | --: | --: |
| grow throughput | 16.6/s | **56.5/s** (3.4×) |
| burst throughput (20 clients) | 9.2/s | **56.9/s** (6.2×) |
| slowest single append, burst | **2305 ms** | **380 ms** (6.1×) |

⚠ RED's 2305 ms worst-case append at a **253 MB** store is already over half of
production's 4000 ms append timeout. Production's store is **4.0 GB** — ~16×
larger. That is the `"timed out after 4s"`, reproduced.

## Batteries

Seal **6/6 CAUGHT**, burst **3/3 CAUGHT**, green baselines throughout. Every arm
asserts the anchor applied, the test actually ran (`running N`, N>0), and the
verdict.

⚠ **Four arms survived first, and every one was a defect in the guard, not the
fix:**

- `scan` was **not** segment-aware while `read_execution` was — silent data loss
  on every scan after a seal. Found because a test used `std::env::set_var`,
  which is process-global, and armed sealing inside an unrelated sibling
  (`concurrent_appends_to_one_tier_stay_readable` went 24 records → 8). The
  threshold is now **injected**; no test touches env.
- The fail-safe cap test **re-implemented** the parse instead of calling it, so
  deleting the real filter left it green.
- The accept-loop guard matched the substring `acquire_owned`, which
  `try_acquire_owned` also contains — a non-blocking acquire would have passed.
- The digit-suffix check was **redundant** with `parse::<u64>()`; removing it
  changed nothing, so it is gone rather than left as a second rule that can
  drift.

Also: the seal tests first landed **between `#[cfg(test)]` and `mod tests`**,
rebinding the attribute so they silently never ran — caught only because the
filter returned 10 tests instead of 14.

## Not fixed here

The **per-append state clone itself** is unchanged. Removing it needs either a
faithful non-mutating validation pass or structural sharing inside
`ReferenceDatabase` — and copy-on-write at the top level would not help, because
every tier append touches the one big collection. Both change the append
semantics of a tier that is `primary` in production. The seal makes the clone
cheap by making the state small, which is the same win without that risk.

## Infrastructure landmine found

`.dockerignore`'s `**/target` is a **name** match, so it also excluded
`vendor/cc/src/target/` — a legitimate source module of the vendored `cc` crate.
The offline build failed with `failed to open /app/vendor/cc/src/target/llvm.rs`,
which reads like a corrupt vendor rather than an ignore rule. Fixed with an
explicit `!vendor/**`.
