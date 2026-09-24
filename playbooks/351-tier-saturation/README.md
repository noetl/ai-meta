# Tier saturation gates (noetl/ai-meta#351, noetl/worker#341)

Three read-only kind gates measuring what CPU-bound tier load does to a writer at
`cpu=2`, against a **prod-shaped fixture**: a sealed `eventlog.jsonl.1` of
1,020,001,271 bytes (973 MiB).

| script | question |
| :-- | :-- |
| `starvation-gate.sh` | single load level, RED vs GREEN, with a saturation assertion |
| `sweep-gate.sh` | load sweep 1/2/4/8, classifying SERVED vs SHED vs TIMEOUT |
| `process-gate.sh` | **does the PROCESS stay able to answer for itself** |

`gate-pod.tmpl` replicates the prod `noetl-cmdbus-writer` container env.

## Result, 2026-09-24

**Process responsiveness — the property that broke prod** (registration starved
past a hardcoded 30s; the metrics face unanswered):

| arm | idle (control) | under 8 sustained readers |
| :-- | :-- | :-- |
| RED `origin/main` | 34ms, 513 lines | **30024ms, 0 lines** |
| GREEN worker#341 | 47ms, 513 lines | **19ms, 529 lines** |

Idle controls agree (513/513); RED's timeout reproduced twice.

**A cost-free tier read under load — fails on BOTH arms.** RED times out at 2s at
every level; GREEN sheds in 1.0s (and breaks the pipe once the waiter queue, `8 *
cap`, is full). A cap of 1 protects the runtime and worsens head-of-line blocking
inside the tier.

## ⚠⚠ Four ways these gates lied before they worked

Every one produced a confident, wrong, *clean-looking* result.

1. **A podman `COPY --from=builder` served from cache while the builder stage
   genuinely recompiled for 2m44s.** Both arms were byte-identical to a 45-hour-old
   image while the log showed a real compile. Fix: `ARG CACHEBUST` before the COPY,
   and assert the arms differ **in the right way** (the clamp string: 0 in RED, 1
   in GREEN), not merely that they differ.
2. **`tier-load` ignores both timeout controls** —
   `TierClientConfig::build(Some(&addr), None, None)` hardcodes 2s, so
   `--timeout-ms` and `NOETL_EHDB_TIER_SERVICE_TIMEOUT_MS` do nothing. Readers
   cannot be held open, so the harness counted **0 concurrent readers while
   believing it had 8** and still printed a verdict. Sustain load by reconnecting.
3. **`tier-load` reports `ok:true` for an explicit REFUSAL.** `TIER_BUSY_REPLY` is
   exactly **173 bytes**; an idle read of an empty tier is **117**. A sweep read
   GREEN as *serving* at every load level when all of it was shed. Classify on
   bytes. (noetl/ai-meta#353)
4. **The metrics face binds late**, so a first idle scrape returned 0 lines on one
   arm only — making the arms non-comparable while both "passed". The idle
   positive control is now enforced on **both** arms before anything is measured.

The general rule: **a gate whose saturation assertion fails has proved nothing,
however plausible its verdict.** Two runs here reported "RED starved / GREEN
answered" and had to be thrown away.
