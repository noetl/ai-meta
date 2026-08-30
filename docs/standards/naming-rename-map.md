# Risk-classified rename map

Companion to [`naming-conventions.md`](naming-conventions.md). **Phase 1 —
nothing has been renamed.** Measured 2026-08-30 against the running cluster.

## The headline numbers

| class | size | meaning |
| :-- | --: | :-- |
| **SAFE-INTERNAL** | **~198 env vars + ~all Rust symbols + docs** | no external contract; rename freely |
| **LIVE-CONTRACT** | **109 env vars, 3 known-scraped metrics, 161 route paths** | renaming can break prod, or worse, **silently revert a flag to its default** |

⚠ The ratio is the useful part: **the overwhelming majority of the churn is
free.** The dangerous set is small and enumerable, which means the owner can take
the whole SAFE tier now and decide the LIVE tier separately.

---

## SAFE-INTERNAL — no external contract

### S1. Rust type/variant casing — 1 rename
`StoreTier::Eventlog` → `StoreTier::EventLog`
(`worker/src/ehdb/store_tier.rs`). The codebase writes the type as
`EventLog`/`D1EventLog` 15 times; this variant alone lowercases the L.

### S2. Env vars **declared but not set on any prod workload** — ~198
Includes the two `_SECONDS` outliers, both confirmed **code-only**:
- `NOETL_EHDB_READINESS_TIMEOUT_SECONDS` → `..._SECS`
- `NOETL_SECRET_PROVIDER_TTL_SECONDS` → `..._SECS`

⚠ **Caveat before treating all 198 as free:** "not set on the six prod workloads"
is not "set nowhere". Kind manifests, CI, `ops/ci/manifests/**` and developer
shells also set these. The check that makes a given one safe is
`grep -r VAR repos/ops` **plus** a kind run — not this list alone.

### S3. Module/file names — 0 renames
`snake_case` is already universal; the 2 kebab exceptions are `src/bin/*.rs`,
which the standard explicitly permits.

### S4. Crate names — 0 renames
All 11 `ehdb-*` crates already comply.

### S5. Domain vocabulary in prose/docs — mechanical
`eventlog` is already unanimous in code (231 vs **0**). Only prose needs
normalising, and prose has no contract.

### S6. Git commit prefix — 1
`playbooks:` (1 use) → `playbook:` (26 uses). Affects future commits only.

---

## LIVE-CONTRACT — needs a compatibility path

### 🔴 L1. `ehdb_feed_subject_lag` — **the single most dangerous rename**

**KEDA scrapes it.** The `noetl-worker-rust` ScaledObject triggers on
`ehdb_feed_subject_lag{subject="commands.shared.shard.0"}`.

⚠⚠ KEDA's `metrics-api` scaler in `format: prometheus` matches `valueLocation`
as a **prefix of the whole `name{labels}` token** and takes the first matching
line. It has **no label selector**. So a renamed series does not produce an
error — it produces a **scaler error**, and the pool **falls back instead of
scaling**. Silent, and only visible as capacity that never arrives.

**Compatibility path:** emit **both** names for a full deprecation window →
update the ScaledObject → confirm the pool still scales under load → only then
drop the old series. ⚠ Do not reverse those steps.

### 🔴 L2. The 22 bare `ehdb_*` metrics → `noetl_ehdb_*`

3 are known-scraped today:
- `ehdb_feed_subject_lag` (KEDA — see L1)
- `ehdb_l0_unreplicated_age_seconds` (2 alert policies)
- `ehdb_l0_durability_sample_ok` (1 alert policy)

The other 19 have no known consumer **but absence of a known consumer is not
absence of a consumer** — dashboards are not in this repo.

**Compatibility path:** dual-emit old + new for one window; migrate alert
policies via `ci/monitoring/apply-alertpolicies.sh` (idempotent, matches on
displayName); then drop.

### 🔴 L3. The 109 env vars set on prod — **the silent-revert class**

⚠⚠ **This is the failure mode that matters.** Renaming `NOETL_X` to `NOETL_Y`
while the Deployment still sets `NOETL_X` does not error. The new code reads
`NOETL_Y`, finds nothing, and **falls back to its default** — so the flag
silently reverts. Every one of these is fail-safe-defaulted *by design*, which
means a botched rename looks exactly like a healthy deployment.

Six were set live **today** and are the sharpest examples:
`NOETL_EHDB_SEAL_MAX_AGE_MS`, `NOETL_CATALOG_READ_SOURCE`,
`NOETL_CATALOG_LOG`, `NOETL_CATALOG_SNAPSHOT`,
`NOETL_DATABASE_ROUTES_AUTH`, `NOETL_EHDB_RECOVERY_SOURCE`.

**Compatibility path — read both, old wins as fallback:**

```rust
fn var(new: &str, old: &str) -> Option<String> {
    std::env::var(new).ok().or_else(|| {
        let v = std::env::var(old).ok();
        if v.is_some() { tracing::warn!(%old, %new, "deprecated env var still set"); }
        v
    })
}
```

Then: deploy the dual-read → update manifests → confirm the deprecation warning
stops → drop the old name. ⚠ **A metric or log line for "old name still in use"
is mandatory**, because without it the only signal that the migration is
incomplete is the flag silently doing nothing.

⚠ `<VAR>_FILE` (`server/src/secrets/file_env.rs:103`) is **computed**, so renaming
`NOETL_X` silently renames `NOETL_X_FILE` too. That pairing carries the three
bootstrap secrets. Any rename of a `_FILE`-backed var must migrate both.

### 🟡 L4. Routes — 161 paths, 2 concrete proposals

- `/api/catalog-log/*` (3) → `/api/catalog/log/*`
- `/ui_schema` → `/ui-schema` (the 1 snake outlier vs 31 kebab)

**Compatibility path:** serve both, old aliased to new, for one release; the CLI
and gateway are the callers to check first.

### 🟡 L5. DB columns — **not surveyed, deliberately**

Column renames are migrations against a table the server does not own — ⚠ prod
already learned this: the server cannot add a column to `noetl.catalog`, which is
why the soft-delete predicate had to be conditional. **Recommend excluding DB
columns from this exercise entirely** unless the owner wants a separate,
migration-shaped project.

---

## Recommended split for the owner

1. **Take all of SAFE-INTERNAL now** — ~198 env vars (with the S2 caveat
   checked per-var), 1 type variant, prose. No compatibility path needed, no
   prod risk.
2. **Take L4 routes next** — small, aliasable, low blast radius.
3. **Defer L1/L2 metrics** until someone can enumerate the dashboards. The KEDA
   one alone can silently stop the user pool scaling.
4. **Do L3 env vars last, in small batches**, each with dual-read + a
   deprecation warning, and never batch a rename with any other change — so that
   if a flag does silently revert, the cause is unambiguous.
5. **Exclude DB columns.**
