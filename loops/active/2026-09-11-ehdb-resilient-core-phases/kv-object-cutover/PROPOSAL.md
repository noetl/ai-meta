# KV / object tier cutover — proposal, and the recommendation is **do not flip**

**Status: OWNER DECISION ARTIFACT. Nothing here has been executed.**
Prepared 2026-09-16 against prod `sts/noetl-server-rust-embedded` v3.109.5,
workers v5.132.5. Every number below was measured, not carried forward.

---

## 1. Recommendation

**Do not flip KV or object to primary-serve.**

⚠ **Updated 2026-09-16.** The original reason was that the blockers sat two
layers earlier than #321 — the tiers were not readable, had no durable store,
and had no comparator. **That work is now done and kind-proven** (§2), so the
recommendation no longer rests on it.

It now rests on three things, none of which is engineering:

1. the prod rollout is blocked on the **writer-pin** question (§8);
2. **noetl/ehdb#321** is open, and its acceptance is explicit — *"no tier flips
   to primary-serve until this is merged"*;
3. the **substrate decision** (§3) is unmade, and it is the same question for
   these tiers as for the event log.

What changed is that (1) and (3) are now the only things between here and an
*evidence-based* decision, rather than an absence of evidence.

## 2. Measured readiness

> **Readiness updated 2026-09-16.** Prerequisites 0, 1 and 2 are built and
> kind-proven. The table below is current; the strikethrough row records what it
> said before, because the difference is the work.

| tier | durable shadow store | readable via tier service | parity comparator | state |
| :-- | :-- | :-- | :-- | :-- |
| **eventlog** | n/a (is the tier) | **yes** | yes — *now trustworthy*, noetl/ai-meta#346 | `primary`, serving |
| **projection** | n/a | n/a (server-side WAL read) | yes | serving **99.88%** |
| **object** | **yes**, writer PVC — survives a pod roll | **yes** (was 501) | **yes**, false-alarm-proof | shadow; **not deployed to prod** |
| **kv** | **yes**, same | **yes** (was 501) | **yes**, same comparator | shadow; no traffic yet |

*Was, on 2026-09-16 morning:* ~~object — ephemeral `/tmp`, HTTP 501, no
comparator; kv — no metrics at all, HTTP 501, no comparator.~~

**Kind-proven, end to end:**

* shadow records **survive a pod roll** (5 records, identical digests, across
  brand-new pods; `/tmp/ehdb` on those pods empty) and keep accumulating
  (11 records across a pre-roll and a post-roll execution);
* shadow digests **match the source object bytes** exactly;
* the comparator reports `match` on healthy data with **5 superseded records
  counted, not alarmed** — the case a naive comparator would have called 5
  divergences;
* a **genuine** planted defect is caught (`authoritative 000000000000 vs shadow
  7404912ce859`) and clears on repair;
* coverage is honest: `unmirrored: 194` with a prefix, the field **omitted**
  without one, and `no_comparable` rather than a free `match` on an empty tier.

Verbatim, from prod:

```
GET /api/ehdb/tiers/kv      → 501 "the tier service serves the eventlog tier only;
                                   the kv tier must be read with NOETL_EHDB_TIER_QUERY_SOURCE=local"
GET /api/ehdb/tiers/object  → 501  (same)
```

Tier-service operations exposed: `append`, `append_batch`, `conn`, `health`,
`read_execution`, `scan`, `unsupported`.
Parity comparator tier labels in prod metrics: **`eventlog` and `projection` only.**

`tier_store.rs` states the scope in its own module doc: *"KV, object and vector
still have no store here; they gain one in the same change set that gives them a
`StoreTier` variant, not before."* The 501 is that sentence, enforced.

## 3. The finding that outranks the cutover question

**Prod's event-log tier is `primary` and it is RF=1 on a non-replicated store.**

* `NOETL_EHDB_EVENTLOG_BACKEND` is **unset on every prod workload**, so
  `EventLogStorageBackend::from_raw` fail-safes to `LocalReference`.
* `tier_store::driver()` constructs a `LocalReferenceEventLogDriver`
  **unconditionally** — there is no code path from the tier service to the
  durable segment stack.
* `ehdb-reference`'s own doc on that backend: *"Default; correct for `shadow`,
  **not production-durable under `primary`**."*
* Therefore `build_durable_stack` never runs, `REPLICA_DOMAINS` is never
  initialised, and `ehdb_replica_domains_observed` reads **0** — correctly. The
  Phase-3 failure-domain guard is not dead wiring; it is a guard for a stack
  that is not deployed.

So the shape today is: one JSONL store per tier, in a directory on **one
ReadWriteOnce PVC**, attached to **one** `cmdbus-writer` pod.

⚠ This reframes #321. The issue asks for election + fencing *before a tier is
promoted*. The event-log tier was already promoted, onto a substrate with **no
replicas to elect between and no second writer to fence against**. The fencing
decorator exists and can be armed (`ehdb_fencing_active`), but its own comment
says it observes nothing without an election (noetl/ehdb#331).

**This is not an outage and not data loss** — a PVC is durable storage and the
data is there. It is a gap between the durability the `primary` label implies
and the durability the substrate provides, and it should be decided
deliberately rather than inherited.

## 4. Ordered prerequisites for a KV/object flip

> **Amended 2026-09-16 after building step 1 and finding it unbuildable.**
> A step 0 was missing, and it invalidates the premise of the two steps after
> it. See noetl/ai-meta#348.

0. **A durable store for the kv/object shadow tiers.** Today they write to
   `/tmp/ehdb` — the container's writable layer, with **no volumeMount** — so
   the shadow data is destroyed on every pod roll. Measured across three pods:
   each store was created within ~3 minutes of its own pod's start, and a pod
   rolled at 08:49 had no store at all. `object_ops_total{mirror} 34` reads like
   a tier accumulating evidence; it is a count since this pod started, against a
   store that will not outlive it.
   **A shadow tier exists to accumulate the evidence that justifies a cutover,
   and this one cannot accumulate anything across a restart.**

1. **A tier-service read path for kv/object.** Today they answer 501. A tier
   that cannot be read through the serving surface cannot serve. This is the
   `StoreTier` variant + store file work `tier_store.rs` names.
2. **A per-tier parity comparator.** Without one there is no evidence the shadow
   copy agrees with the authoritative store. noetl/ai-meta#346 is the cautionary
   case: an *untrustworthy* comparator is worse than none, because it trains
   operators to ignore the signal that guards the tier.
3. **noetl/ehdb#321 merged.** Its acceptance is explicit and is not a judgement
   call: *"Gate: no tier flips to primary-serve until this is merged."* Open.
4. **A durability decision for the substrate** (§3). Flipping a second and third
   tier onto the same single-copy store multiplies the exposure of a gap that is
   already there for the event log.

Prerequisites 0, 1 and 2 are **additive and reversible** — real forward progress
toward the cutover with no irreversible step. 3 is a document. 4 is owner-only.

⚠ **0 blocks 1 and 2, not merely precedes them.** A read path over an ephemeral
store advertises a surface that answers empty in a way indistinguishable from a
misconfigured writer — the exact shape `store_tier.rs` refuses (*"a tier gains a
variant in the same change set that gives it a store"*). And a comparator over
it would report `missing_event` after every roll until the shadow caught up,
which is noetl/ai-meta#346's lesson repeated on a new tier.

⚠ **The cheap-looking fix is worse than the problem.** Pointing
`NOETL_EHDB_LOCAL_REFERENCE_LOG` at a mounted volume does not work for the user
pool: it runs 2+ replicas with no shared volume, so each would accumulate a
*different* partial shadow — durable-looking and unmergeable. The store belongs
behind the tier service on the writer's PVC, like the event log and the catalog
log.

## 5. Rollback analysis — and why "reversible" is the wrong word

The flag is reversible; the **consequences are not symmetric**.

| what | reversible? |
| :-- | :-- |
| `NOETL_EHDB_KV=primary` → back to `shadow` | yes, one env var, one roll |
| reads served from the tier while primary | **no** — answers already returned to callers |
| writes accepted only by the tier while primary | **depends** — if the authoritative store is still dual-written, yes; if not, the window's writes exist only in the tier |

So the question that decides rollback is: **during primary-serve, is the
authoritative store still written?** For the event log the answer is yes (the
mirror is additive and Postgres remains authoritative), which is what made the
D3 projection flip genuinely reversible. For KV and object that answer is
**unknown, because neither has a comparator to establish it.**

*A cutover is rollback-able exactly to the degree that the old store is still
being written. Nobody should flip a tier whose answer to that is "unknown".*

Precedent worth copying: D3 did **not** need its flag to start serving. Serving
began when noetl/server#431 fixed the #335 double-apply and the digests agreed;
the flag was armed afterwards, for 0.1% of reads. **Correctness came first and
the flag followed.** That is the shape to repeat.

## 6. What would have to be true to flip — checklist

- [ ] `GET /api/ehdb/tiers/{kv,object}` returns records, not 501.
- [ ] A parity comparator exists per tier, with a control battery that plants a
      **real** defect per class. ⚠ noetl/ai-meta#346: the event-log `order`
      control planted a *non-defect* and certified a check that false-alarmed on
      36.9% of prod traffic. A control suite is only worth its weakest fixture.
- [ ] That comparator reads **≥ 99% agree over a soak with a denominator large
      enough to mean something.** #346's own lesson: 13 fresh executions produced
      1 refold; it took a 22-hour window to reach 19,818.
- [ ] Both controls pass: the comparator detects every planted class, **and** an
      untouched execution reads `not_comparable` rather than `agree` — so
      `agree` is not the default.
- [ ] noetl/ehdb#321 merged.
- [ ] The dual-write question in §5 answered **in writing**, per tier.
- [ ] A rehearsed revert, executed once against kind, with the metric that would
      trigger it named in advance.
- [ ] §3 decided: either the durable segment backend is adopted, or `primary` on
      a single-copy store is an accepted, recorded risk.

## 7. What I would do next instead

**Prerequisite 0**, then 1, then 2 — a durable store for the kv/object shadow
tiers behind the tier service, then the read path, then the comparator. All
three additive, all three reversible, none of them the irreversible flip.

The ordering is not a preference. 1 and 2 were attempted first and are not
buildable on an ephemeral store; that attempt is what found §4.0.

⚠ **Read the two "not ready" findings together.** §3 says the event-log tier is
`primary` on a single-copy store. §4.0 says the kv and object shadow tiers are
on ephemeral storage. Both are the same question wearing different clothes:
**the EHDB tiers' durability substrate has not been decided**, and each tier has
inherited a different provisional answer. The cutover question cannot be
answered per-tier until that one is.


---

## 8. The writer pin — the one thing blocking the prod rollout

`sts/noetl-cmdbus-writer` runs `sha256:c13b2957…`, a **different digest** from
the worker pools' v5.132.5 (`sha256:14759cee…`). `memory/current.md` records it
as held back deliberately; the reason is not written down anywhere I could find.

It matters because **rollout order is load-bearing**. On a writer that predates
the change, `StoreTier::parse("object")` returns `None` and every shadow append
is refused — correctly labelled `append_failed` rather than lost silently, but
nothing accumulates. I hit exactly that on the first kind attempt.

### The documented sequence, for when the pin is cleared

1. `sts/noetl-cmdbus-writer` → new image. *(Appends refused until this lands.)*
2. `deploy/noetl-worker-system-pool` → new image. *(Tier reads relay via
   `NOETL_EHDB_WORKER_QUERY_URL` → this pool, so reads 501 until it lands.)*
3. `deploy/noetl-worker-rust` → new image.
4. `sts/noetl-server-rust-embedded` → new image (the comparator endpoint).
5. Verify: `GET /api/ehdb/tiers/object?limit=5` → 200 with
   `serve_state: "not_wired"`; `GET /api/ehdb/object-parity/object` → `match`;
   records accumulate across a subsequent roll.

Every step is an image roll with the previous image as its rollback. **Nothing
authoritative changes at any point** — KV's incumbent stays NATS-KV, object's
stays the external object store, and `kv`/`object` stay out of
`SERVE_WIRED_TIERS` with three tests failing if that changes.

⚠ One config prerequisite, additive: `NOETL_EHDB_CLIENT_ROLE=worker` must be set
on any pool expected to mirror — `object::runtime_hook_env` returns `None`
without a data-plane role and the hook is simply absent, silently. **Prod already
has it** on both worker pools; kind did not, which is how it was found.
