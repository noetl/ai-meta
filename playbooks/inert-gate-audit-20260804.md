# Inert-gate audit — 2026-08-04

Six times in one session a mechanism turned out to be **present, plumbed, tested,
and incapable of doing anything.** None was caught by a test suite; all six were
green. This records the pattern, the check that finds it, and the results of
running that check deliberately across the EHDB gate surface.

---

## The pattern

A gate has two halves, and a test suite normally covers only the first:

1. **The logic** — given input X, the gate does Y. Unit-testable, and in every
   case below it was correct and tested.
2. **The reachability** — can X ever arrive? Needs a *producer*, a *call site
   passing real state rather than a placeholder*, and an *exposed signal* if
   anyone is to observe it.

A gate that fails (2) passes its own tests, logs cheerfully, and asserts nothing.
Worse, it reads as evidence: a green paired-evidence run over an inert path looks
exactly like a green run over a working one.

## The six

| # | mechanism | how it was inert | found by |
| :-- | :-- | :-- | :-- |
| 1 | `ehdb_l0_out_of_order_appends` | computed, never rendered on `:9102` | #206, before today |
| 2 | `ehdb_l0_recovered_active_records` | added in ehdb#313, never rendered — a SIGKILL test could not tell "absent" from "zero" | running the test the fix was written for |
| 3 | `ehdb_events_group_lag == 0` | reads identically for *drained* and *never-published* | trying to use it as a gate ([#230](https://github.com/noetl/ai-meta/issues/230)) |
| 4 | Feather-GC sink gate (#199 Slice B) | read a **hardcoded empty set** | the PR's own description |
| 5 | …then read `noetl.sink_pending`, which **had no producer** | grep for callers of the endpoint | after wrongly claiming #286 fixed it |
| 6 | L0 crash recovery | recovered on first *append*, so a **read** saw nothing and `append_writer_assigned` minted a key below the recovered tip | writing an engine-level test instead of a writer-level one |

Note #5: the fix for #4 produced #5. Moving inertness is easy to mistake for
removing it.

## The check

For any gate, three greps. All three must return a non-test hit:

```bash
# 1. Is the flag read at all?
grep -rn '"NOETL_MY_GATE"' --include="*.rs" src

# 2. Is there a PRODUCER for the state the gate reads?
grep -rn "the_endpoint_or_setter" --include="*.rs" src | grep -v test

# 3. Does the call site pass real state, or a placeholder?
#    (this is the one that catches `None` / `HashSet::new()` / `vec![]`)
grep -rn "gate_fn(" -A 3 --include="*.rs" src
```

Step 3 is the one people skip. #4 and #6 were both `Some(...)`-vs-placeholder
bugs at a single call site, invisible from the gate's own module.

For a metric, the equivalent of (3) is: **is it rendered at zero?** A counter
that only materialises once non-zero cannot distinguish "nothing happened" from
"this build lacks the metric" — which is how #2 wasted a test run.

## Results of running it across the EHDB gate surface

| gate | logic | reachable | verdict |
| :-- | :-- | :-- | :-- |
| `NOETL_SINK_GATE_EVICTION` (in-process sink gate) | ✓ | ✓ producer on the real dispatch path (`command_declares_sink`) | **honest** |
| durable-segment GC sink gate (#199 Slice B, worker side) | ✓ defers the pass on `any_sink_pending()` | ✓ `worker.rs:348` passes `Some(self.state_builder_index.clone())` | **honest** — I had wrongly listed this as outstanding |
| Feather result-tier GC sink gate (#199 Slice B, server side) | ✓ | ✗ → **fixed today** by worker#218 | was #5 |
| `NOETL_AUTOSINK` / `NOETL_AUTOSINK_TARGET` | ✓ | ✗ — `has_target()` is used only in a log line and tests | **inert by design, and says so** |
| `NOETL_EHDB_EVENTLOG_GC` | ✓ | ✓ | honest |
| `NOETL_NONCONVERGENCE_SWEEP_ENABLED` | ✓ | ✓ proven end-to-end in kind (12/12 PC, 0/550 NC) | honest |

### The distinction that matters

`NOETL_AUTOSINK_TARGET` is read, stored, logged, and **never acted on** — and
that is *fine*. `autosink.rs`'s module doc says so in its first paragraph: the
slice ships "the loop + config + the pure eligibility policy + candidate
metrics", and "writes nothing to any store". Inert **and documented as inert** is
a shipped shadow slice.

Inert **while described as working** is the defect. That was #4 and #5.

So the audit question is not "is this reachable?" but **"does the claim match the
reachability?"** A doc comment saying "observe-only, writes nothing" is a pass. A
PR description saying a gate is now "real" over a feed with no producer is not.

## What to do with this

- When reviewing a gate PR, ask for the step-3 call site in the diff. If the
  reachability is in a different file than the logic, it is not being reviewed.
- When adding a metric, render it at zero.
- When writing the test, write it at the layer the defect can live at. #6 passed
  every writer-level test and was still broken at the engine level.
- When a fix makes something reachable, re-run the *original* symptom rather than
  the unit test. #5 existed because I checked the plumbing and asserted the
  behaviour.
