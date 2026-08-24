# Decision: the planner's inlined provider code is authoritative

- **Date:** 2026-08-24
- **Status:** Accepted (owner decision)
- **Issue:** [noetl/ai-meta#295](https://github.com/noetl/ai-meta/issues/295)
- **Arises from:** [#286](https://github.com/noetl/ai-meta/issues/286) (inlining), [#175](https://github.com/noetl/ai-meta/issues/175) (raw provider body)

## Decision

The **authoritative** copy of the HotelBeds provider dispatch code is the code
**inlined in the travel planner**:

```
noetl/travel : playbooks/itinerary-planner.yaml
  steps  call_hotelbeds_hotels / call_hotelbeds_book
         call_hotelbeds_activities / call_hotelbeds_transfers
```

That is what production runs, as registered catalog
`muno/playbooks/itinerary-planner`.

Every other copy is a **non-authoritative mirror** and must not be edited on its
own:

| Copy | Status |
| :-- | :-- |
| planner inline (`noetl/travel`) | **AUTHORITATIVE** |
| `noetl/ops : automation/agents/mcp/hotelbeds{,-activities,-transfers}.yaml` | mirror — kept for remaining callers |
| registered `automation/agents/mcp/hotelbeds*` in the catalog | mirror — registered from the ops file |

## Reconciliation requirement

A change to provider dispatch lands in the **planner first**, then is mirrored
into `noetl/ops` **in the same change set**.

- A fix made only in the mirror **never reaches production**.
- A fix made only in the planner **leaves `hotel-cards` behind**.

## Why the mirrors cannot simply be deleted

They still have callers. Checked against the **live catalog** (226 paths), not
the repo:

- `muno/playbooks/hotel-cards` (v3) — a real, live playbook.
- `muno/playbooks/_probe-empty-results` — the #290 verification probe, pending
  operator archive ([#294](https://github.com/noetl/ai-meta/issues/294)).
- ~13 historical `itinerary-planner-*-validate` / `-candidate` snapshots from
  past sessions.

Retiring the MCP playbooks would break `hotel-cards`. Deleting registered
playbooks also requires an operator: `/api/catalog/delete` returns **403**,
locked since the soft-delete incident.

## What this decision cost to discover

The two copies had diverged **in both directions**, and each looked correct in
isolation — which is the whole hazard:

| | ops mirror | registered / live |
| :-- | :-- | :-- |
| #175 fix (do not surface the raw provider body) — activities + transfers | present | **never registered** |
| project name | retired `noetl-demo-19700101` ×4 per file | correct `shastaratech-noetl-prod` |

Consequences:

1. **Production never had the #175 fix** for activities and transfers. The
   planner builds `error_card.description` from the provider's `summary`, so a
   raw `{...auditData...}` blob could reach the UI.
2. **#286's inlining faithfully copied the unfixed version** into the planner —
   the inlining was correct, the source it copied was not.
3. Overwriting the mirror with the live content — the obvious "fix the stale
   repo" move — **would have deleted the #175 fix**.

Both halves were merged: #175 is in all copies and the retired project name is
gone. Registered as `itinerary-planner` **v98**.

## Guard

```bash
./playbooks/drift-audit.sh provider-inline
```

Compares each planner-inline step against its ops mirror and reports the
evidence — character counts, whether the #175 fix is present on each side,
whether the retired project name appears. Verified to **fire before** the
reconciliation and **pass after**; a check that has never fired is
indistinguishable from one that cannot.

## Alternatives rejected

- **Generate the inline copy from the mirror at build time.** Cleanest in
  principle, but there is no build step for playbooks today, and adding one to
  settle a two-file duplication is disproportionate.
- **Retire the mirrors.** Breaks `hotel-cards`, and deletion needs an operator.
- **Accept duplication with no guard.** This is what already existed, and it
  hid an unshipped bug fix for months.

## Related

- [`agents/rules/representation-drift.md`](../../agents/rules/representation-drift.md)
  — a copy is true only while something forces it to agree. This is that rule
  applied to source code rather than to a manifest or a status column.
- [#294](https://github.com/noetl/ai-meta/issues/294) — the probe playbook
  awaiting operator archive.
