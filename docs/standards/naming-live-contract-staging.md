# Live-contract naming — staged, not applied

**Nothing here has been renamed.** This is the one-step-ready plan for the tiers
`naming-rename-map.md` classified LIVE-CONTRACT, with the sizes re-verified
against the code rather than taken from the map.

## ⚠ The map's L2/L4 figures do not survive verification

| map says | verification |
| :-- | :-- |
| 22 bare `ehdb_*` metrics | **unresolved.** A quoted-literal scan finds 22; a bare-identifier scan finds 140, most of which are function and variable names. Neither is the answer — metric names are emitted three different ways (a quoted const, a `format!`, and a whole pre-rendered line like `"ehdb_l0_durability_sample_ok 1\n"`, which the quoted scan misses entirely). A trustworthy total needs an extractor that parses the render functions, not a grep. |
| 3 metrics known-scraped | **8.** See below. The map understated the consumed set by more than 2×. |
| 161 routes | **unresolved.** `main.rs` has 107 `.route(` calls but only 29 distinct inline `"/..."` literals, because most calls put the path on the following line. 161 is not reproducible from either number. |

The consumed set is what actually needs aliases, and that IS pinned.

## Tier A — the 8 metrics with a real consumer (dual-emit required)

Every one is referenced by an applied ops artifact. These are the renames that
can break something.

| metric | → | ops references | what breaks if renamed without an alias |
| :-- | :-- | --: | :-- |
| `ehdb_feed_subject_lag` | `noetl_ehdb_feed_subject_lag` | 4 | ⚠⚠ **KEDA scaler.** `metrics-api` prefix-matches the whole `name{labels}` token, so a rename silently yields no metric → the scaler reads 0 → the pool scales to zero. |
| `ehdb_feed_total_lag` | `noetl_…` | 7 | ScaledObject + PodMonitoring |
| `ehdb_feed_shard_lag` | `noetl_…` | 4 | alertpolicies.json + PodMonitoring |
| `ehdb_feed_shard_committed` | `noetl_…` | 1 | PodMonitoring |
| `ehdb_l0_unreplicated_age_seconds` | `noetl_…` | 4 | 2 alert policies — **and the D1 window observed on prod 2026-08-31** |
| `ehdb_l0_unreplicated_records` | `noetl_…` | 3 | alert policies + runbook |
| `ehdb_l0_durability_sample_ok` | `noetl_…` | 2 | 1 alert policy. ⚠ Emitted as a pre-rendered line, so a quoted-name scan does not see it — the class of miss that produced the "3" figure. |

**Alias mechanism.** Emit both names from the same renderer for one deprecation
window, then drop the bare one:

```rust
// render both until the window closes; the value is computed once
out.push_str(&format!("{OLD} {v}\n"));
out.push_str(&format!("{NEW} {v}\n"));
```

Cost: 8 extra series per scrape. Ordering that makes it safe:

1. Dual-emit ships and is deployed. **Verify both names appear on `/metrics`.**
2. Migrate consumers — `apply-alertpolicies.sh` is idempotent and matches on
   `displayName`; the KEDA ScaledObject and PodMonitorings are ordinary applies.
3. **Verify KEDA still scales** — this is the step that must not be skipped, and
   the only honest check is watching a scale event, not reading a manifest.
4. Only then drop the bare name.

⚠ Steps 1 and 4 are separate deploys. Collapsing them is the failure.

## Tier B — 4 routes (serve both)

| route | → | note |
| :-- | :-- | :-- |
| `/api/catalog-log/verify` | `/api/catalog/log/verify` | verified present, `main.rs:385` |
| `/api/catalog-log/coverage` | `/api/catalog/log/coverage` | `main.rs:389` |
| `/api/catalog-log/backfill` | `/api/catalog/log/backfill` | `main.rs:393` |
| `…/ui_schema` | `…/ui-schema` | `main.rs:103`. ⚠ It is a **wildcard tail** route (`/api/catalog/{*tail}`) matched by suffix, not a literal path — so the alias is a suffix check, not a second `.route()`. |

**Alias mechanism:** register the new path and point it at the same handler;
keep the old registered for one release. Callers to check first are the CLI and
the gateway.

## What is NOT staged

- **The 109 deployed env vars.** Their compatibility path (read both, old wins)
  is sound, but the failure mode is a *silent revert to default* rather than an
  error, and it needs the per-variable manifest audit that
  `naming-rename-map.md` §S2 already showed is easy to get wrong — 457 of 574
  names appear in some config surface, not the 109 the map first counted.
- **DB columns.** Deliberately unsurveyed.

## Recommendation

Do **Tier A alone**, as its own change, with the four ordered steps above and a
human watching step 3. Tier B is cosmetic and can wait; the env vars should not
move until the audit is redone.
