# M0.5 E2 + E5 — results

Branch `feat/m05-tier-backend` (worker), commit `7195d47`. Mutation battery
**7 / 7 CAUGHT** with a green baseline on every arm; full lib suite
**815 passed / 0 failed**. Run `./m05-mutation-battery.py <worker-checkout>`.

With E1/E3/E4 already landed, **M0.5's exit criteria are complete**. Nothing is
deployed anywhere; the flag defaults to `local_reference`.

## E2 — byte-identity differential, N = 64

`the_dispatch_under_local_reference_is_byte_identical_to_the_incumbent`
compares the new `driver_for(.., LocalReference)` dispatch against a directly
constructed `LocalReferenceEventLogDriver` — *the code that runs today*, not a
second copy of the new code — over **64 appends**, on both the produced store
bytes and every `EventLogAppendOutcome` field.

- The outcome is compared through `Debug`, so a field added later is covered
  without anyone remembering to extend a list.
- No normalisation is needed: the reference driver stamps no clock, so the
  bytes are deterministic. (Checked by running it, not assumed.)
- The test asserts the store actually holds the appends (>1000 bytes) — a
  differential over two empty files passes trivially.

**The spec's planted defect #5 ships as two controls, not one**, because the
differential has two arms and a single control cannot show both are live:

| control | outcomes | bytes | isolates |
| :-- | :-- | :-- | :-- |
| a **same-length** differing payload | identical (`byte_len` unchanged) | must differ | the byte arm |
| a **different-length** payload | must differ | differ | the outcome arm |

## E5 — `ehdb_tier_backend_info{backend}`

Pinned at 0 for every value in `TIER_BACKENDS` and 1 for the running one,
recorded from the **resolved flag** in `driver_for` before construction — so a
pod whose `l0` store fails to open still reports `l0`, which is what the
operator configured and what the refusal is about.

Two decisions worth stating, because they pull in opposite directions:

- **Unconditional with respect to the flag.** Opening under `local_reference`
  still emits the `l0` series at 0. Pinning only the selected value leaves the
  other absent, and absent is what a binary with no backend dispatch also
  renders — the exact confusion the gauge removes. (server#315 pinned
  publish-skip reasons inside a config branch and lost them on the one
  configuration that mattered.)
- **NOT unconditional with respect to having a tier store at all.**
  `without_a_listener_the_tier_service_renders_nothing` holds that a worker with
  EHDB off emits no EHDB lines; a process that never opened a store has no
  backend to report, and inventing `l0=0` there would be a claim about a store
  that does not exist. The render therefore sits **outside** `if
  s.tier_service_up` (a store can be opened without serving requests) and inside
  its own `tier_backend_up` gate.

`every_known_backend_is_pinned` asserts the denominator: adding a `TierBackend`
variant without adding it to `TIER_BACKENDS` fails there rather than silently
shipping a gauge that omits the new engine.

`the_dispatch_records_which_backend_it_selected` is the reachability half — the
recorder existing is not the recorder being called, which is how four dead
recorders were found in this codebase.

## Mutation battery — 7 / 7

| # | planted defect | caught by |
| :-- | :-- | :-- |
| M1 | dispatch ignores the flag, always `local_reference` | the l0 round-trip test |
| M2 | dispatch ignores the flag, always `l0` | the E2 byte-identity test |
| M3 | cross-backend read returns Ok with the other engine's records | the E4 refusal test |
| M4 | an unrecognised flag value falls through to `l0` | the fail-safe test |
| M5 | the gauge pins only the selected backend | the both-values test |
| M6 | the recorder exists but the dispatch never calls it | the reachability test |
| M7 | the pin moves inside a config branch (the server#315 shape) | the reachability test |

Each arm asserts the anchor was found, the mutation applied, and the test
actually ran (`running N tests`, N>0), against a green BASELINE.

## Name deviation, stated

The spec writes `ehdb_tier_backend_info`; that exact name is used, unprefixed,
even though the surrounding families on the same renderer are `noetl_ehdb_*`.
The endpoint already mixes both conventions (`render_election` emits `ehdb_*`),
and matching the spec's literal name keeps a grep for it from coming back empty.
