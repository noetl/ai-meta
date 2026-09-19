# ai-meta#332 M5 — election + fencing: kind results (2026-09-19)

Kind only. **Not enabled in prod**, and no prod flag moved.

## ⚠⚠ The finding that changes M5's risk assessment

**Fencing is wired but NOT ON ANY LIVE PATH — in kind or in prod.**

`FencedSharedBackend` is constructed only inside `build_durable_stack`, which
runs only when `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment`. Measured:

| workload | `NOETL_EHDB_EVENTLOG_BACKEND` |
| :-- | :-- |
| kind `noetl-cmdbus-writer` | **UNSET** ⇒ `local_reference` |
| prod `noetl-cmdbus-writer` | **UNSET** |
| prod `noetl-worker-rust` | **UNSET** |
| prod `noetl-worker-system-pool` | **UNSET** |

Corroborated behaviourally rather than only from config: the writer has **no
`.fencing` directory** on its PVC and serves **no `ehdb_fencing_*` series at
all**.

Two consequences, and they point in opposite directions:

1. **The M5 spec's blast-radius line is currently false.** It says *"⚠⚠ Highest
   in the program. The first thing that can refuse a production write, on a tier
   that is already `primary`."* Flipping `NOETL_EHDB_FENCING=enforce` today
   would refuse nothing, because nothing constructs the fenced backend. The
   outage risk the spec warns about arrives only when `durable_segment` is
   *also* selected.
2. **And the protection is equally absent.** Single-writer-per-shard still rests
   entirely on `StatefulSet replicas: 1` regardless of the fencing flag, which
   is precisely what M5 exists to end.

So M5's exit criterion E3 — *"in kind, a deliberately stale-epoch write is
refused"* — **cannot be met without also selecting `durable_segment`**, which is
M0.5 territory and changes where event bytes live. That is stated here rather
than worked around, because a gate that reported E3 green against a path nothing
executes would be the exact defect this program keeps paying for.

## What IS proven in kind

**The token issuer is real.** `ShardElection` had **no call sites anywhere**
before this session; it now runs and mints a token from a genuine Kubernetes
Lease.

```
ehdb_election_active        1
ehdb_election_epoch         1
ehdb_election_rounds_total  4     <- climbing: the loop is turning, not wedged
ehdb_election_errors_total  0
```

```
INFO noetl_worker::ehdb::election: EHDB shard lease ACQUIRED
     shard=0 epoch=1 identity=noetl-cmdbus-writer-0
     setting="observe" applies_to_writes=false
```

The apiserver's own view:

```yaml
name: ehdb-shard-00000000
spec:
  holderIdentity: noetl-cmdbus-writer-0
  leaseTransitions: 1
  leaseDurationSeconds: 15
  renewTime: "2026-09-19T22:08:14.216000Z"
```

⭐ `applies_to_writes=false` under `observe` — the ladder rung doing its job.

| arm | result |
| :-- | --: |
| `off` | **12 / 12** — no thread, epoch 0, no lease, gauges present at 0 |
| `observe` | **13 / 13** — lease acquired, epoch 1, rounds climbing, errors 0 |

RBAC applied to kind with before/after controls: `no` → `get/create/update: yes`,
**`delete: no`** (withheld deliberately — a writer that can delete the lease can
erase the record that fences it). ⚠ In prod this grant is owner-run.

## The refusal, proven where it is reachable

The M5 spec's planted defects, run against `ehdb-reference`'s integration suites
(green baseline: 6 + 12 + 12):

| # | planted defect | verdict |
| :-- | :-- | :-- |
| — | BASELINE, unmutated | passes (not caught) ✔ |
| #2 | `Enforce` accepts a **lower** epoch | **CAUGHT** (two tests) |
| #3 | CAS ignores `expected_version` ⇒ two holders | **CAUGHT** |
| #5 | `shadow` refuses instead of counting | **CAUGHT** |

⚠ The first run reported #3 as SURVIVED. The mutation had **never applied** —
the anchor text did not match — so the verdict described nothing. The runner now
asserts the mutation applied *and* that the test actually RAN before believing
it. Third instance of this class in one session.

## Two guards that passed accidentally

The codebase left two placeholders to fail the moment the election was wired.
Neither fired:

- `the_election_reports_itself_as_not_running` pinned the **string**
  `ehdb_election_active 0`, which the derived renderer still emits when nothing
  is elected.
- `the_election_is_still_unwired_in_this_build` scanned `eventlog_backend.rs`,
  `command_bus.rs`, `event_bus.rs` — the wiring landed in `worker.rs` /
  `ehdb/election.rs`, **outside the scanned population**.

Replaced with the property: inert and elected must render **differently**
(`the_election_gauges_are_derived_not_hardcoded`), plus the round counter that
separates "not the holder" from "wedged". Both mutation-checked.

## Remaining to E2/E3

1. Select `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment` in kind (M0.5 work) so
   the fenced backend is actually constructed.
2. Plant a stale epoch in the shard marker; assert `stale_epoch` refusal and
   `ehdb_fencing_refused_total` climbing; restore and assert the elected writer
   proceeds.
3. `observe` in prod first, counter watched, **owner-gated**; `authoritative`
   only simultaneously across writers — ⚠ the hazard is **mixed** epochs, not
   enforce-without-election.
