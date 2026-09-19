# ai-meta#332 write-side spine — session results (2026-09-19)

Kind only. **Nothing deployed to prod, no prod flag moved.** Every flag added in
this session is default-off and inert.

## 1. DIGEST — the residual `digest_mismatch` is closed

**Root cause: a THIRD un-hydrated leg.** `d1bb0820` fixed the verifier's
reference policy; it did not reach `events_for_recovery_or_postgres`, whose two
rungs build **different representations of the same events** — the Postgres rung
goes through `events_from_postgres_hydrated`, the spine rung returned whatever
the tier held, raw. `materialize_from_wal` folds and **digests** whichever one
answered.

Measured in kind on 3 × `muno/probe/big-parent` (a clean +7 delta): the tier held
**two records at the same version and the same `applied_count`** with different
digests, separated only by provenance —

```
seq=14301 ac=12 mirror_source=server     digest=2bf8078b…   (hydrated)
seq=14302 ac=12 mirror_source=wal_spine  digest=8c740d82…   (raw)
```

and the body diff was exactly the reference envelope: `_store` plus the whole
`extracted` block on one side and absent on the other — the fingerprint
`d1bb0820` recorded as unexplained. Whichever record won the
`(version, sequence)` race decided `match` vs `digest_mismatch`, which is why it
was intermittent and why every execution's FINAL record still agreed.

Second, latent, fixed alongside: `fold` and `fold_with_body` applied **different
normalisations** (`normalise_null_json` on one only) — the stored record and the
state it is verified against, normalised differently.

| | before (`refspolicy`) | after (`spinehydrate`) |
| :-- | --: | --: |
| `digest_mismatch`, 3× big-parent | **+7** | **0** |
| `match` (the positive control) | +20 | **20** |
| bounded per-record verification | **5/21 diverge** | **0/58 diverge** |
| same-version / different-digest records | multiple | **0** |

Both `wal_spine` and `server` legs ran in every execution, so the zero is not a
leg going missing.

**How it was found, and how it was NOT.** By folding captured prod-shaped data
offline through the REAL serve-path functions — not through
`/api/ehdb/projection-fold/diff/{id}`, which folds tier EVENTS rather than the
stored SNAPSHOT, applies a normalisation the serve path does not, and is not on
the serve path at all. It reports agreement on exactly the executions the serve
path rejects.

Lands: `noetl/server` `fix/verifier-reference-policy` @ `eb31ef25`.
Mutation battery 4/4, 1129 lib tests green.

## 2. PROJECTOR — both flags, proven two-sided

The two flags live on **different components**: `NOETL_PROJECTOR_ENABLED` on the
worker (the drain loop), `NOETL_PROJECTOR_OWNS_SNAPSHOT` on the server.

| arm | config | `digest_mismatch` | records / disagreements |
| :-- | :-- | --: | :-- |
| A | both on (**single writer**) | **0** (match 20) | 58 / **0** |
| B | `OWNS_SNAPSHOT=false` (**two writers**) | **0** (match 14) | 50 / **0** |

Arm B carried *more* `server` records (10 vs 8), so the orchestrator really was
self-writing and the two-writer condition was genuinely exercised.

⚠ **Correction to the working assumption.** The "two-writer contention /
divergence already observed" was a **symptom of the representation asymmetry**,
not of write contention. With every leg folding identically, two writers now
produce the *same* digest. Kind restored to single-writer.

Projector counters: `drained=452 = acked=452`, `held=0` — no backlog, no errors.

## 3. FENCING (M5) — built, unit-proven, kind pending

- **`KubeLeaseStore`** — a plain-HTTPS `coordination.k8s.io/v1` Lease client
  implementing `ehdb_reference::election::LeaseStore`, in the **worker**.
  ⭐ Deliberately not `kube`/`k8s-openapi`: `ehdb-reference` has **no HTTP client
  at all**, and the surface needed is three verbs on one resource. Adds **no new
  dependency** (reqwest `blocking` is a feature on an existing dep; `ehdb-core`
  was already transitive). Reversible in one file — it sits behind the trait.
- **The election ladder** — `NOETL_EHDB_ELECTION` = `off` | `observe` |
  `authoritative`. ⚠⚠ The hazard is **mixed epochs**, not
  enforce-without-election: all-zero is self-consistent and writes succeed; what
  refuses every un-elected writer is ONE node minting epoch 1. `observe` proves
  the lease/CAS/failover in the real cluster with the write path still on 0.
- `render_election` now reports the real state — it was a hardcoded `0` that
  could only ever say "inert", and would have gone on saying it while an
  election ran. Plus `ehdb_election_rounds_total` as the positive control for
  `active` (a wedged loop also reports `active=1` forever).
- RBAC applied to kind with clean controls: `no` → `get/create/update: yes`,
  **`delete: no`** (withheld — a writer that can delete the lease can erase what
  fences it). ⚠ In prod this grant is owner-run.

Lands: `noetl/worker` `feat/m5-kube-lease-store` @ `83c6b21`.
13 unit tests, mutation battery 4/4, 816 lib tests green.
**Not enabled anywhere** — `NOETL_EHDB_ELECTION` unset ⇒ off ⇒ epoch 0.

## 4. ENGINE WIRING — M1, M4, M2

- **M1** `ReplicaTarget.locality`, undeclared by default (silence is not
  independence).
- **M4** `L0Config.survival_goal` + `validate_region_survival` at the
  `check_replica_domains` call site. Inert under the default `Zone`.
- **M2** `EventRecord.commit_hlc` + the engine stamp, in one change.

⚠ **Scope correction:** the brief estimated "~29 EventRecord construction
sites". There is **exactly one** struct literal; the other 28 are function
RETURN types (`-> EventRecord {`). The 29 came from a grep that counts a
pattern, not the property.

Lands: `noetl/ehdb` `feat/write-side-wiring` @ `271beaf`.
Mutation batteries 5/5 (M2), ehdb workspace green.

## Remaining

- **M5 kind proof** — image building; arms in
  `playbooks/332-m5-fencing/gate.sh`.
- **Item 5, the L0-backed tier driver** (M0.5) — not started. Spec's entry
  criterion is M0 exit, which the read-side session owns and has not pushed
  (`feat/m0-resolvers` is still at `main`).

## Prod

Untouched and unverified-against this session beyond read-only checks. Every
flag added here is default-off. No prod deploy, no prod flag change.
