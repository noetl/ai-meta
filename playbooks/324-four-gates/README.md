# The four gates — sequencing plan

The F1–F5 remediation for [ehdb#324](https://github.com/noetl/ehdb/issues/324)
is merged and **inert**. Four switches remain, and each changes what the system
*does* rather than what it reports.

> ## ⛔ None of these is flipped. Each is one command from go, and each is
> owner-gated. Three of the four touch the **live writer path on an event-log
> tier that is already `primary` and serving prod**.

## The dependency, stated first

They are **not** independent, and the order is not a preference:

```
  G0  observability          ehdb#328 / worker#290   ← LANDED, deployed
       │
       ├──────────────┐
       ▼              ▼
  G1  seal age    G2  fencing shadow→enforce
      ehdb#329        ehdb#330
       │              ▲
       │              │  requires a real token
       │              │
       │         G3  election authoritative
       │             ehdb#331
       ▼
  G4  replica-set validation at open
      ehdb#332   (requires a second substrate to exist)
```

- **G0 gates everything.** Without the append-relative window metric, none of the
  others can be verified before *or* after — the pre-existing lag metric is
  seal-relative and blind to the dominant term.
- **G2 depends on G3.** Enforcing stale-epoch refusal while every writer's epoch
  is `0` (no election running) means the *first* writer to advance the marker
  fences every other one permanently. **Enforce before the election is issuing
  real tokens and you take an outage.** This is the single most dangerous
  ordering error available here.
- **G3 depends on G2 shadow** having read 0 for a soak. If shadow is already
  counting stale writes, promoting the election converts a silent problem into
  refusals.
- **G4 depends on a second substrate existing** (an owner dependency decision),
  and is independent of G1–G3.
- **G1 is independent of all of them** and is the cheapest real durability win.

## ⚠⚠ A prerequisite discovered 2026-08-30 that blocks G2 and G4

**Both fencing (G2) and the replica-domain observation (G4's verify-before) live
inside `build_durable_stack`, and prod never calls it.**

`build_durable_stack` runs only when
`NOETL_EHDB_EVENTLOG_BACKEND=durable_segment`. Prod leaves it **unset**, so
`selected_backend` returns `LocalReference` and the durable-segment stack is
never constructed. Verified on the running writer: `ehdb_replica_domains_observed`
reads **0**.

Consequences:

- **G2's verify-before is still unsatisfiable on prod.** Setting
  `NOETL_EHDB_FENCING=shadow` alone changes nothing, because the decorator it
  configures is inside a stack that is never built. It needs
  `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment` as well.
- **G4's verify-before cannot be answered from prod** for the same reason.

⚠⚠ **And that second flag is not an observability toggle — it is a storage
backend switch.** It changes which store serves the event log on a tier that is
already `primary`. It therefore belongs in the gated set, not in the inert set,
and it is a **new prerequisite the original plan did not name**.

So the honest dependency is:

```
  G0  observability            ← done
       │
  G-pre  NOETL_EHDB_EVENTLOG_BACKEND=durable_segment   🔴 OWNER GATE (storage switch)
       │
       ├──────────────┐
       ▼              ▼
  G2  fencing     G4  replica-set validation
```

Nothing about G1 or G3 changes: G1's seal-age knob is read by the writers
directly, and G3's election is blocked on the `kube` dependency decision instead.

---

## Recommended order

**G1 → G3 → G2 → G4.** G1 first because it is independent, reversible by one
flag, and closes the unbounded window. Then the election, then enforcement once
tokens are real, then validation whenever a second substrate lands.

---

## G1 — age-based sealing ([ehdb#329](https://github.com/noetl/ehdb/issues/329))

**What changes:** parts seal on age as well as size/count, so an idle shard's
records reach the substrate instead of sitting on one disk indefinitely.

⚠ **Two steps, and the second touches the live writer loop.** The flag alone is
inert: `should_seal()` is only consulted on append, and the shard the trigger
protects is the one taking no appends. Something must drive
`seal_aged_parts()` on a timer.

| step | verify before | enable | verify after | rollback |
| :-- | :-- | :-- | :-- | :-- |
| **G1a** timer (code) | `ehdb_l0_unreplicated_age_seconds` present on prod | ship the writer timer calling `seal_aged_parts()`; with `seal_max_age` unset it is a no-op | `seals` rate unchanged; window unchanged | revert the image |
| **G1b** flag | max unreplicated age over a soak, **including an idle shard** | set `seal_max_age=5s` | max age falls below ~2× the limit; part count rise measured | unset the env var, roll |

**One-command rollback:** `kubectl -n noetl set env statefulset/noetl-cmdbus-writer NOETL_EHDB_SEAL_MAX_AGE-`

⚠ Expected cost: more, smaller parts on idle shards. Measure part count before
and after; L0.3 compaction absorbs it, but the number should be *seen*, not
assumed.

---

## G2 — fencing enforcement ([ehdb#330](https://github.com/noetl/ehdb/issues/330))

**What changes:** the shared store starts **refusing** writes from an epoch below
the highest it has accepted.

⚠⚠ **Do not flip this before G3.** With no election running every writer's epoch
is `0`; the first write advances the marker to 0 (no advance), and any writer
that later presents a *lower* epoch is refused. The moment a real epoch appears
alongside stale `0`s, the `0`s stop writing. **Enforce-before-election is an
outage, not a degradation.**

| verify before | enable | verify after | rollback |
| :-- | :-- | :-- | :-- |
| `ehdb_fencing_stale_observed_total` **== 0** over ≥24 h of shadow, and `ehdb_fencing_epoch_advances_total` > 0 (proving the path is live, not merely quiet) | `NOETL_EHDB_FENCING=enforce` | `stale_refused_total == 0`; append rate unchanged; `ehdb_l0_unreplicated_age_seconds` flat | unset the env var, roll |

⚠ **A shadow counter of 0 is only evidence if the path is reachable.** Check
`writes_checked_total` is climbing. A zero from an unreached decorator looks
exactly like a healthy zero — the reachability trap, again.

---

## G3 — authoritative election ([ehdb#331](https://github.com/noetl/ehdb/issues/331))

**What changes:** the writer refuses to append without a lease token, so
single-writer stops resting on `replicas: 1`.

⚠⚠ **This makes Kubernetes API-server availability a dependency of the write
path.** A writer that cannot renew its lease stops writing. That trade — refuse
rather than risk a fork — is correct, and it is a genuine new failure mode.

**Prerequisites, all owner-run:**
1. The K8s `LeaseStore` adapter (needs the HTTP/`kube` dependency decision).
2. The RBAC Role in `docs/spec/lease-election-k8s-binding.md` — ⚠ **no `delete`
   verb**: deleting a lease discards `leaseTransitions`, the next acquisition
   mints epoch 1 again, and a **reused epoch is worse than no epoch**.

| verify before | enable | verify after | rollback |
| :-- | :-- | :-- | :-- |
| election running in shadow; token issued; a forced pod delete advances `leaseTransitions` by exactly 1 | flip the writer to require a token | writer holds a lease; appends continue; `stale_observed` still 0 | revert to not requiring a token, roll |

---

## G4 — replica-set validation at open ([ehdb#332](https://github.com/noetl/ehdb/issues/332))

**What changes:** a replica set that does not spread failure domains makes the
writer **fail to start** instead of silently providing RF 1.

⚠⚠ **Prod today would fail this check.** `NOETL_EHDB_TIER_SERVICE_DIR` is inside
`NOETL_EVENT_BUS_WRITER_DIR` on one PVC — a nested root on a shared device. So
enabling validation before fixing the layout is a **startup outage by
construction**, not a risk.

Order is therefore forced: second substrate → repoint → *then* validate.

| verify before | enable | verify after | rollback |
| :-- | :-- | :-- | :-- |
| `check_replica_domains` reports **no** violations against the live paths | turn validation on at open | writer starts; `survives_node_loss` true | revert the image |

---

## What is NOT gated here

Landed and safe: the F4 metrics (observability), F2's shadow counters, F1's
election running non-authoritatively, F5's failure-domain types and second
substrate. All merged inert; none of them changes a byte of writer behavior.
