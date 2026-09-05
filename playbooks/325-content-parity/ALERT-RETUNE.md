# Enabling the content comparison without paging blind

**Status: not enabled anywhere. This is the procedure, not a record of doing it.**

`NOETL_EHDB_CROSSSTORE_PARITY_CONTENT` widens the cross-store comparator from
three identifying fields to the content fields the fold actually reads
([noetl/ai-meta#325](https://github.com/noetl/ai-meta/issues/325)).

## Why the flag exists at all

The comparison is strictly better. Turning it on is not.

Today `noetl_ehdb_crossstore_divergence_total` feeds **"NoETL EHDB: tier diverged
from the authoritative event log"**, which pages on
`sum(increase(noetl_ehdb_crossstore_divergence_total[10m])) > 0`. The tier
diverges in content on a large share of executions **and has for as long as the
mirror has existed** — the comparator simply could not see it. Arming the flag
converts those from `match` to `divergent`.

So a flag flip alone pages immediately, on a condition that is not new, is not
an incident, and that nobody can action at 3am. **The flag and the alert move
together or neither moves.**

## Order of operations

1. **Measure first, alert unchanged.** Arm the flag on ONE server replica, or
   run the on-demand endpoint (`GET /api/ehdb/parity/executions/{id}`) with it
   armed. That route records nothing — `ParityRecording::Inspect`,
   [#264](https://github.com/noetl/ai-meta/issues/264) — so it cannot move the
   counter the alert reads. Get the real content-divergence rate before
   deciding anything.

2. **Re-point the alert before arming the sampler.** The existing rule must stop
   treating `kind="content"` as pageable until the baseline is understood:

   ```promql
   # was
   sum(increase(noetl_ehdb_crossstore_divergence_total[10m])) > 0
   # becomes — page on the kinds that mean data loss, not on content
   sum(increase(noetl_ehdb_crossstore_divergence_total{kind!="content"}[10m])) > 0
   ```

   and add a separate, non-paging record/threshold for `kind="content"` so the
   rate is visible while it is characterised.

3. **Then arm the sampler**, fleet-wide.

4. Only once content divergence is genuinely rare does `kind="content"` belong
   back in the paging expression.

## What to expect when you measure

The divergence is **systematic, not random**: the tier holds the **inlined**
result where Postgres holds a **`reference`** pointer. The comparator already
treats that pair as one logical result (`collapse_result_representation`), so it
should *not* appear — the `result_representation` control asserts exactly that
on every tick. If the measured rate is still high, the difference is something
else and is worth reading before re-tuning anything.

⚠ The collapse asserts the two forms are **equivalent, not equal** — the pointer
is never dereferenced. A tier holding an inlined payload that does not match what
its reference resolves to is invisible to this comparison. Closing that needs the
reference resolved, which is a different piece of work.

## Rollback

Unset the variable. The comparator returns to the three identifying fields and
every verdict is byte-identical to before; the `content` label stays pinned at 0,
so "off" reads as zero rather than as an absent series.

## Related

- [#325](https://github.com/noetl/ai-meta/issues/325) — the finding and the two-oracle problem.
- [#264](https://github.com/noetl/ai-meta/issues/264) — why the on-demand route is safe to sweep with.
- `agents/rules/representation-drift.md` — absent is not zero; a pinned label set is why "off" is readable.
