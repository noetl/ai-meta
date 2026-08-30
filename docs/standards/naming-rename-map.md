# Risk-classified rename map

Companion to [`naming-conventions.md`](naming-conventions.md). **Phase 2 applied 2026-08-30** — see
*Phase 2 outcome* below. Measured 2026-08-30 against the running cluster.

## The headline numbers

| class | size | meaning |
| :-- | --: | :-- |
| **SAFE-INTERNAL** | ~~~198 env vars~~ **0 env vars** + Rust symbols + docs | no external contract — but see the S2 correction |
| **LIVE-CONTRACT** | **109 env vars, 3 known-scraped metrics, 161 route paths** | renaming can break prod, or worse, **silently revert a flag to its default** |

⚠⚠ **The headline ratio above was wrong, and applying the tier is what found
it.** "Free" was measured as *not set on the six prod workloads*. Re-measured
against **every** config surface — 3,322 files across `ops`, all submodules, CI,
kind manifests, and ai-meta's own docs and playbooks — **457** distinct `NOETL_*`
names appear *somewhere*, leaving only **117** truly code-only. Both `_SECONDS`
outliers are among the 457, so **the SAFE tier contains no env-var rename at
all**. The set that needs care was never 109; it was 457, and the map understated
it four-fold.

This is the map own S2 caveat coming true. It named the right check
(`grep -r VAR repos/ops` **plus** kind) and then published a headline computed
without it. A caveat printed under a number does not correct the number —
readers take the number.

---

## SAFE-INTERNAL — no external contract

### S1. Rust type/variant casing — ✅ APPLIED (worker#303)
`Eventlog` → `EventLog`, **42 identifier occurrences across 8 worker files** —
not the 1 estimated here. The variant is re-spelled at every match site and in
`QueryTier`, `MirrorSource`, and the metrics renderers.

⚠ The "15 competing uses" figure was also wrong. It came from a `\bEventLog\b`
pattern, whose trailing boundary excludes `EventLogOutcome`, `D1EventLogPart`,
and every other prefixed form. Comment-stripped and prefix-inclusive, the real
counts are **`EventLog` 560 vs `Eventlog` 39** — the same conclusion, from a
number off by 37×. A word-boundary pattern is a claim about the boundary as much
as about the word.

Safety was proven rather than asserted: the multiset of string literals removed
by the diff is **identical** to the multiset added, so the adjacent live literals
`"eventlog"` (the tier label in metrics and config) and `"eventlog.jsonl"` (the
on-disk store name, whose rename would present a populated store as empty on the
component serving primary) are untouched. `StoreTier` derives no `Serialize`, so
the variant has no serialised form.

### S2. Env vars — ~~198~~ **0 renames** (retracted)
Both `_SECONDS` outliers were listed here as "confirmed code-only". Under the
stricter check **neither is**:
- `NOETL_EHDB_READINESS_TIMEOUT_SECONDS` → ❌ appears in config surfaces
- `NOETL_SECRET_PROVIDER_TTL_SECONDS` → ❌ appears in config surfaces

Of the 117 names that *are* genuinely code-only, **zero violate the standard** —
they were already `NOETL_<AREA>_<THING>_<UNIT>`. The env-var component of the
SAFE tier is therefore empty on both counts: the candidates are not safe, and the
safe ones are not candidates.

⚠ **Caveat before treating all 198 as free:** "not set on the six prod workloads"
is not "set nowhere". Kind manifests, CI, `ops/ci/manifests/**` and developer
shells also set these. The check that makes a given one safe is
`grep -r VAR repos/ops` **plus** a kind run — not this list alone.

### S3. Module/file names — 0 renames
`snake_case` is already universal; the 2 kebab exceptions are `src/bin/*.rs`,
which the standard explicitly permits.

### S4. Crate names — 0 renames
All 11 `ehdb-*` crates already comply.

### S5. Domain vocabulary in prose/docs — no action
`eventlog` is already unanimous in code. Prose uses hyphenated *event-log* as a
compound adjective, which is correct English rather than drift. Nothing to
normalise.

### S6. Git commit prefix — 1
`playbooks:` (1 use) → `playbook:` (26 uses). Affects future commits only;
history is not rewritten.

---

## Phase 2 outcome — what applying the tier actually produced

| set | planned | applied | why |
| :-- | --: | --: | :-- |
| S1 Rust casing | 1 | **42** (worker#303) | the estimate counted the declaration, not the uses |
| S2 env vars | ~198 | **0** | 457 of 574 appear in some config surface; the 117 that do not already comply |
| S3 modules | 0 | 0 | already compliant |
| S4 crates | 0 | 0 | already compliant |
| S5 prose | "mechanical" | 0 | the hyphenation was correct English, not drift |
| S6 commit prefix | 1 | future-only | no code change |

**One PR, 42 symbols, no release, nothing deployed.** `refactor:` is not a
release-triggering type, so no image was built — verified by reading the tag back
after the run rather than assuming it.

### Found while applying, not renamed — two dead types

`GCPTokenRequest` and `GCPTokenResponse`
(`server/src/db/models/credential.rs:139,183`) are the only remaining
non-idiomatic acronym casings in any repo (`GCP`, against the `Gcp` form used
43×). **Both are unreachable**: declared, and referenced by nothing anywhere in
the server repo.

They are deliberately not renamed. Renaming dead code is churn; the real question
is removal, and that is the owner call. The part worth keeping is *why nothing
flagged them*: `db/models/mod.rs` does `pub use credential::*`, and a `pub` item
re-exported from a `pub` module is never dead-code-linted. **A glob re-export
silences the one check that would have caught this** — the same
existence-versus-reachability shape as the F-feature sweep.

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
