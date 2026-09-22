# Why the comparator saw "no comparable records" — root cause, fix, proof

## Root cause: NOT a seal-awareness gap. **My seal broke tier reads.**

The relay body said it all along and I had not read it:

```json
{"action":"ehdb.tier.query","error":"timed out after 2s","outcome":"unavailable",
 "serve_state":"no_durable_service","tier_query_source":"service"}
```

"No comparable records" is only the server's label for a reply containing no
records. The reply contained none because the **worker's tier read timed out at
2 s**.

Split on the seal (22:31:23Z), from production logs:

| window | failures |
| :-- | --: |
| before the seal, 22:00–22:30Z | **0** |
| after the seal, 22:35Z onward | **2259**, all `timed out after 2s` |

⚠ **I previously called this failure pre-existing. That was wrong.** I ran a
100-minute window, saw 501 identical errors, and asserted they spanned the seal
without checking a single timestamp. They did not — essentially all were after
it. The correct check was one `awk` on the timestamp, and it reverses the
conclusion.

**Mechanism.** A merged read consults every sealed segment, and
`read_segment_then_release` forgets each immediately (that release is what keeps
memory bounded). So *every* read re-replays the whole sealed file. Production's
first sealed segment is **1.08 GB** — it cannot be replayed inside 2 s.

Rolling the seal flag back would **not** have fixed it: the `.1` segments
already exist, so reads merge regardless.

## The fix: a per-segment execution index

A sidecar `<segment>.idx` listing the distinct execution ids in that sealed
segment. A read opens only segments that can hold the execution — which works
because the tier mirrors an execution's events over its lifetime, so its records
land in the segment active at the time, almost always exactly one.

- **Sidecar** — the segment's bytes are untouched; a binary ignoring `.idx`
  still reads the segment correctly. No format change, no deletion.
- Built in the **background** on seal (the build replays the segment; the seal
  runs under the store write lock on the append path).
- **Backfilled at startup** for segments sealed by an earlier build — production
  already has two (1.08 GB, 3.3 GB) that would otherwise never be indexed.
- temp-file + atomic rename, so a partial index is never observed.
- ⚠ A **missing** index means "might contain" → the segment is opened. Absence
  must never read as "absent".

## Kind proof — RED reproduces, GREEN holds

Same image, same store, same timeout; the arms differ **only** by whether the
`.idx` files exist.

```
RED  (no indexes): ok=false  "timed out after 250ms"   0 bytes
GREEN (indexes)  : ok=true    0.08s                    1,700,717 bytes
```

⚠ **Scaled, and stated:** production is 1.08 GB in one segment against a 2000 ms
budget. This rig is ~170 MB across 10 segments, where the unindexed read costs
650–1100 ms, so the budget is set to 250 ms on **both** arms. The relationship
under test — read cost exceeds the budget, and the index removes the cost — is
the same; only the scale differs.

Unindexed vs indexed at equal size: **0.67 s → 0.09 s, a 7.4× speedup**, with
byte-identical records (the 1-byte reply delta is the `segments` count rendering
`11` vs `2`).

## Batteries: index 4/4, seal 6/6 (818 tests)

The load-bearing test asserts an indexed read returns **exactly** what an
unindexed read returns, over two interleaved executions — a fixture where every
segment held every execution could not detect a wrong skip. Plus a control that
the index actually rules something out, or it is decorative.

⚠ **Arm I4 survived at first** ("the build drops ids past the first page"): the
other fixtures hold far fewer than `MAX_SCAN_LIMIT` records, so paging never
engaged and they could not exhibit it. Added a test with a segment larger than a
page and an execution appearing only after the boundary.

⚠ **Arm I5 is UNCOVERED and stated, not hidden**: a partial index reading as
complete. The atomic rename is the mitigation; no test here kills the process
mid-write.

⚠ **Seal arm S1 came back ANCHOR NOT FOUND** after this change — the battery
refusing to report a false SURVIVED. Anchor updated; 6/6 again.

## Four harness traps hit while building this gate

Each made a working fix look broken, and none was a defect in the fix:

1. The gate used `--read-only` / `--tier`, which existed only as **uncommitted**
   edits on another branch; `git checkout <branch> -- <file>` pulled that
   branch's committed version, which never had them.
2. `parse_flags` requires a **value** for every flag: a bare `--read-only` is a
   usage error, and an unknown `--flag value` is **silently accepted and
   ignored** — so the probe ran the append path while claiming to read.
3. The probe built its client with `None, None` timeouts, so it used the 2 s
   default and the gate's timeout setting had **no effect**.
4. The wait-for-build loop matched **leftover content** in the log from the
   previous build, so a stale image was loaded and tested twice.

## Sizing note

A 1 MiB seal threshold produced **162 segments** from ~170 MB. Segment count
scales inversely with the threshold, and every unindexed segment is a read cost.
Production's 256 MiB gives ~16 segments for a 4 GB store.
