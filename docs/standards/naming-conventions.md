# NoETL naming conventions

**Status:** Phase 1 proposal — the standard, derived from what the code already
does. **Nothing has been renamed.**

Every rule below is grounded in the **existing majority pattern**, because the
cheapest standard is the one most of the code already follows. Where the majority
is unanimous, the rule just writes it down; where it is split, the rule picks the
larger side and the minority becomes the rename list.

Measured 2026-08-30 across `server`, `worker`, `ehdb`, `cli`, `gateway`, `ops`,
`ai-meta`.

---

## 1. Environment variables / feature flags

### 1.1 Prefix

**Rule: `NOETL_` for anything this platform owns.**

292 distinct `NOETL_*` literals in Rust. Other prefixes exist and are
**legitimate**: `GATEWAY_` (18), `NATS_` (13), `POSTGRES_` (2), `AWS_`/`AZURE_`,
`CARGO_`, `KUBERNETES_`. ⚠ Those name *foreign* systems' conventions and must not
be renamed into `NOETL_*` — a variable an external tool reads is that tool's
contract, not ours.

### 1.2 Sub-namespace

**Rule: `NOETL_<SUBSYSTEM>_<THING>`**, subsystem drawn from the existing set:
`EHDB` (75), `STATE` (43), `EVENT` (21), `RESULT` (18), `COMMAND` (12),
`MATERIALIZER` (9), `CATALOG` (5), `AUTH`, `SECRET`, `TLS`, `K8S`.

### 1.3 Unit suffixes — **the one real split**

| suffix | count | verdict |
| :-- | --: | :-- |
| `_MS` | 28 | ✅ **standard** for milliseconds |
| `_SECS` | 26 | ✅ **standard** for seconds |
| `_SECONDS` | **2** | ❌ outlier — rename to `_SECS` |
| `_BYTES` | 12 | ✅ standard |
| `_COUNT` | 5 | ✅ standard |

**Rule: every duration-valued variable ends `_MS` or `_SECS`; every size ends
`_BYTES`.** A duration with no unit suffix is a defect — the reader cannot know
the unit and the parser cannot warn them.

### 1.4 The `_FILE` convention — **do not break this**

⚠ `server/src/secrets/file_env.rs:103` does `std::env::var(format!("{var}_FILE"))`.
So **`<VAR>_FILE` is a computed contract**: for any `NOETL_X`, setting
`NOETL_X_FILE` supplies the value from a CSI-mounted file instead. Renaming
`NOETL_X` silently renames `NOETL_X_FILE` too, and that pairing is how the three
bootstrap secrets reach prod.

⚠ This convention also defeats naive tooling: a grep for bare `"NOETL_X_FILE"`
literals finds nothing and reports the variable as an orphan. It is not.

### 1.5 Value vocabularies — **four ladders, three different middle rungs**

The platform has four distinct ladder shapes and they disagree:

| ladder | rungs | used by |
| :-- | :-- | :-- |
| serve promotion | `off` → `shadow` → `primary` | tier modes (`NOETL_EHDB_EVENTLOG` etc.) |
| guard enablement | `off` → `shadow` → `enforce` | fencing, `NOETL_INTERNAL_AUTH_MODE` |
| read cutover | `<incumbent>` → `verify` → `tier` | `NOETL_CATALOG_READ_SOURCE` (`postgres`→…), `NOETL_EHDB_RECOVERY_SOURCE` (`spine`→…) |
| backend select | enumerated nouns | `local_reference` \| `durable_segment` |

**Rule: three named ladders, and a variable must use exactly one of them.**

1. **Promotion ladder** — `off` → `shadow` → `primary`.
2. **Guard ladder** — `off` → `shadow` → `enforce`.
3. **Cutover ladder** — `<incumbent-name>` → `verify` → `<new-name>`.

⚠ The cutover ladder deliberately keeps naming its rungs after the *sources*
(`postgres`/`spine` → `verify` → `tier`) rather than being normalised to
`off/shadow/primary`. That is not sloppiness: the off-rung names **which store
answers**, which is the operator's actual question, and flattening it to `off`
would lose that. The rule is that it must be *consistently* source-named.

**Rule: the safe rung is always first, and an unrecognised value parses to it.**
Already the majority behaviour (`parse_mode`, `FencingSetting::from_env`,
`selected_backend` all fail safe); make it universal.

### 1.6 Booleans

**Rule: `NOETL_<...>_ENABLED`, truthy-parsed, default false.** Avoid `_DISABLED`
— a negated flag with a default is read wrong under pressure.

---

## 2. Prometheus metrics

### 2.1 Prefix — **the second real split**

| family | count |
| :-- | --: |
| `noetl_*` | 242 |
| `ehdb_*` | 22 |

**Rule: `noetl_<subsystem>_<thing>`.** The bare `ehdb_*` family exists because
those metrics are declared inside the `ehdb` crates, which do not know they are
running in NoETL.

⚠ **This is the highest-value rename and the most dangerous one**: alert policies
and dashboards scrape these names. Four alert policies applied 2026-08-30 query
`ehdb_l0_unreplicated_age_seconds` directly.

### 2.2 Suffixes

| suffix | count | rule |
| :-- | --: | :-- |
| `_total` | 162 | counters — **required** |
| `_seconds` | 28 | durations — required, and the value is seconds |
| `_bytes` | 3 | sizes |
| `_info` | 4 | build/version gauges, value always 1 |
| none | 67 | gauges — **correct**, gauges take no suffix |

**Rule: counters end `_total`; durations end `_seconds`; gauges take no unit
suffix.**

⚠ `ehdb_feed_total_lag` puts `total` **in the middle** of a gauge name. It reads
as a counter and is not one. Rename to `ehdb_feed_lag_total`… **no** — it is a
gauge, so `noetl_ehdb_feed_lag`. This one name is worth fixing precisely because
it teaches the wrong pattern.

### 2.3 Label names

**Rule: `snake_case`, singular, and a closed label set is pinned at 0 on start.**
Pinning is already the house rule (`Registry::gather` prunes empty families, so
an unpinned labelled metric is absent rather than zero) — this records it.

---

## 3. HTTP routes

| prefix | count |
| :-- | --: |
| `/api` | 106 |
| `/noetl` | 11 |
| `/context`, `/ingress`, `/state`, `/secrets`, `/reference` | 1–8 each |

**Rule: `/api/<namespace>/<resource>`, kebab-case, plural resources.**
Kebab is already near-unanimous — **31 kebab segments vs 1 snake** (`/ui_schema`).

⚠ Two structural inconsistencies:
- `/api/catalog` (7) and `/api/catalog-log` (3) are **siblings** where the second
  is a sub-resource of the first. Should be `/api/catalog/log/...`.
- `/api/internal` (27) is the largest namespace and is a *trust boundary*, not a
  resource. Keep it — but the rule is that `/api/internal/**` means
  "service-account only", and nothing else may live there.

---

## 4. Rust identifiers

Already highly consistent; the rules mostly ratify it.

- **Crates**: `kebab-case`, subsystem-prefixed — all 11 ehdb crates comply
  (`ehdb-core`, `ehdb-l0`, …).
- **Modules / files**: `snake_case`. **2 exceptions**, both binaries
  (`ehdb-local-reference.rs`, `ehdb-selfcheck.rs`) where kebab matches the bin
  name. **Rule: kebab is allowed for `src/bin/*.rs` only.**
- **Types**: `PascalCase`. ⚠ One outlier: `StoreTier::Eventlog` should be
  `EventLog` — the codebase writes the type as `EventLog`/`D1EventLog` 15 times
  and this variant alone lowercases the L.
- **Env-var constants**: `SCREAMING_SNAKE` ending `_ENV`, already the pattern
  (`MODE_ENV`, `SEAL_MAX_AGE_ENV`, `FENCING_ENV`).

---

## 5. Domain vocabulary

### 5.1 `eventlog` — **already unanimous, no action**

| form | count |
| :-- | --: |
| `eventlog` (code) | 231 |
| `event_log` (code) | **0** |
| `EventLog` (types) | 15 |
| `event-log` (prose) | 247 |

**Rule: `eventlog` in identifiers and env vars, `EventLog` in type names,
"event log" in prose.** Nothing to rename — this is recorded so it stays true.

### 5.2 engine vs tier vs store — **the vocabulary that actually confuses**

Four overlapping "which source" types exist: `StoreTier` (124 uses),
`EventLogStorageBackend` (54), `QueryTier` (38), `FoldSource` (15).

**Rule, per `docs/SCOPE.md`:**
- **engine** — one of the four owned capabilities: event log, projection, KV,
  object. There are exactly four; the word is not available for anything else.
- **tier** — a *configuration selector* with an `off`/`shadow`/`primary` mode.
- **store** — a concrete durable backing (a `StoreTier` variant, a
  `DurableSubstrate`).
- **source** — where a *read* was answered from (`FoldSource`).

⚠ `catalog` has a `StoreTier` but is **a projection, not a fifth engine** — a
thing gains a store without gaining an engine. `vector` has neither.

---

## 6. Git / process

Commit prefixes actually used in `ai-meta` (last 200): `chore` 86, `docs` 61,
`playbook` 26, `fix` 5, `test` 2, `handoff` 2, `memory` 1, **`playbooks` 1**.

**Rule: the set is `chore|docs|fix|feat|test|playbook|handoff|memory`, singular.**
`playbooks` (1 use) is the outlier.

⚠ And the load-bearing one, already in `agents/rules/release-versioning.md`:
**only `feat:`/`fix:`/breaking trigger a release.** A `chore:` or `docs:` change
that must reach a cluster will merge green and never produce an image.
