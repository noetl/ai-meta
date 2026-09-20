# Step 4 — projector shadow soak: coverage is 0%. Not flip-ready.

**2026-09-20, prod. The projector was NOT enabled and is not enabled now** —
`NOETL_PROJECTOR_ENABLED` / `NOETL_PROJECTOR_OWNS_SNAPSHOT` are unset on the
server and on all four worker pods (verified on the running pods, not the spec).

## The numbers, with the denominator

Window: the full life of the new server pod, boot 22:58:02Z → 23:45Z (~47 min),
721 log lines.

| | value |
| :-- | --: |
| **Denominator** — distinct executions seen | **9** |
| events persisted | 231 |
| projection-mirror attempts | **3** |
| distinct executions the mirror even attempted | **1 of 9 (11%)** |
| mirror attempts that **succeeded** | **0 of 3 (0%)** |
| cross-store parity samples | 9 |
| cross-store parity samples yielding a **usable verdict** | **0 of 9 (0%)** |
| projection parity verdicts | **0** |

**Effective coverage: 0%.** Nothing was mirrored, and no comparator produced a
verdict. Reporting "0 divergences" from this would be the vacuous pass — the
population the mirror was offered is one execution, and it failed.

## Why it is zero — two independent blockers

**1. Every projection-tier mirror times out.**

```
WARN ehdb_projection_mirror: projection tier mirror was refused
  status=502 detail={"action":"ehdb.tier.append","appended":0,
  "errors":["timed out after 4s"],"outcome":"degraded",
  "serve_state":"not_primary","tier_query_source":"service"}
```

3 of 3 attempts, identical error. The tier service lives on
`noetl-cmdbus-writer-0:9110`, whose store is **4.0 GB** and which is the
component that OOM-looped today. A 4-second append budget against that store is
not being met. Until this clears, more traffic only produces more refusals — the
soak cannot improve by waiting.

**2. The cross-store comparator cannot read the tier at all.**

```
WARN ehdb_parity: EHDB cross-store parity: could not read the tier
  outcome="ehdb_unavailable"
  detail=relay to http://noetl-worker-system-pool-metrics...:9090/ehdb/tiers/eventlog failed
```

All 9 samples. The relay target is the system-pool pod, which KEDA churns and
which was rolled during this deploy. An enumerated relay target is a
representation of a workload set, and it drifts the same way a selector does.

⚠ Independently, the multi-region design forbids the parity comparator and the
fold-diff endpoint **as proof instruments**. They are reported here as
*symptoms*, not as the evidence a flip would rest on.

## A third fact that bounds any soak run today

Prod went **idle at 23:07:20Z** and produced zero server log lines for the
following ~38 minutes. Verified not-wedged rather than assumed: the readiness
endpoint answers `{"rows_decoded":1,"status":"ready"}` (so the server is
DB-connected), reached through a port-forward whose **negative control passed** —
killing the forward killed the probe, proving the 200 came from that pod.

So the denominator is small because there is little real work, not because
measurement is broken. A soak that matters needs a window with real load.

## Verdict

**Do not flip.** Three things must be true first, none of which is true now:

1. The projection tier mirror succeeds at a measurable rate (it is 0%).
2. A comparator produces usable verdicts (both produce none).
3. A soak window contains enough real executions to be a denominator worth
   dividing by (9, of which 1 was offered to the mirror).

And ahead of all three: the writer needs to stop OOMing (below), because it is
the tier service that the mirror and the comparator both depend on.
