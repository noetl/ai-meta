# C3 — the failover window, as numbers, and what enforce actually costs

noetl/ai-meta#460 C3. Derived from the shipped driver (noetl/worker#353) and the
fence (`ehdb-reference/src/fencing.rs`). **FLP: every window below is bounded and
none is zero. There is no "instant safe failover".**

Config as shipped: `lease = 15 s` (`NOETL_EHDB_ELECTION_LEASE_SECS`),
`renew = 5 s` (`NOETL_EHDB_ELECTION_RENEW_SECS`, clamped to ≤ `lease/3`).

⚠ Three windows, routinely conflated. They have different bounds and different
consequences, and only the third is the one that risks divergence.

## 1. Unelected window — no writer holds a token

From the predecessor's **last successful renewal**:

- the lease expires at `+lease`. `LeaseRecord::is_expired` is a strict `>`, so at
  exactly `+15.000 s` it is still live;
- the successor retries every `renew`, so its first attempt after expiry lands
  within `+renew`.

> **Upper bound = `lease + renew` = 20 s.**

Excluding pod scheduling and process start, which this design does not bound.

⚠⚠ **This is the availability cost of enforce.** During this window the
successor's `fence_epoch()` is `0`, so with `NOETL_EHDB_FENCING=enforce` **every
durable mutation is refused** — on a writer that hosts both the command bus and
the event bus, which is fleet-wide dispatch. Today, with fencing `off`, the same
20 s costs nothing because an unelected writer writes freely.

So the trade is explicit: **enforce converts ~20 s of unprotected writing per
failover into ~20 s of refused writing.** That is the owner's call, and it is the
whole of what C3 buys and costs.

## 2. Overlap window — both processes believe they hold a token

Bounded by **inter-node clock skew δ**, not by the lease:

- the predecessor evaluates `token_valid` on **its own** clock against **its own**
  last-contact timestamp — same clock, so skew cancels and it stops asserting at
  exactly `last_contact + lease`;
- the successor evaluates `is_expired(now)` on **its** clock against the
  **predecessor's** `renewTime`. A successor clock ahead by δ judges the lease
  expired δ early.

> **Overlap ≤ δ.**

⚠ **δ is not measured.** My read-only attempt (spread of kubelet-written node
`Lease` renewTimes) gives `skew + time-since-last-renewal`, which at 3 nodes
renewing every ~10 s came to 5.855 s — fully explained by staleness with *zero*
skew, so it bounds nothing useful. And my first run of it took three samples
inside one second, before any kubelet renewed, so the three identical readings
were one sample. GKE nodes run NTP and are typically sub-100 ms, but that is a
belief, not a measurement.

A real δ needs in-pod clock reads against a common reference. **It is not,
however, on the critical path — see §3.**

## 3. ⭐ Divergence window — how long the predecessor can still WRITE

**= §2. It is bounded by δ, and it does not depend on the successor at all.**

⚠ My first derivation of this section said the window ran until the successor's
*first fenced mutation* and was therefore traffic-dependent and "not a bound".
That was wrong, and the mechanism that makes it wrong is the one shipped in
noetl/worker#354:

- the predecessor's `fence_epoch()` reads `token_valid`, which goes false at
  `last_contact + lease` **on its own clock**;
- it then hands the fence `0`;
- the ledger marker already holds the predecessor's own epoch (≥ 1), and
  `0 < marker` ⇒ `Stale` ⇒ **refused under enforce**.

So the predecessor **self-fences** at `last_contact + lease`, whether or not the
successor has written anything, whether or not the successor even exists. The
successor's marker advance (`transitions + 1` on its first fenced write) is a
*second* line of defence, not the primary one.

> **Divergence window ≤ δ**, the same clock-skew term as §2: the predecessor
> stops at `+lease` on its clock, the successor starts at `+lease` on its clock.

⚠⚠ **This holds only while the marker is non-zero**, and that is a hard
precondition rather than a detail. With an empty ledger, the predecessor's
degraded `0` meets a marker of `0`: `0 < 0` is false ⇒ `Fresh` ⇒ **not refused**.
A fence armed before any epoch has ever advanced therefore fails to catch exactly
the case it exists for, while reporting `writes_checked` climbing and
`stale_observed 0`.

That is why `epoch_advances ≥ 1` below is a **safety** gate, not a liveness one.
I had it in the acceptance table for the wrong reason before working this through.

### A tightening, now optional rather than required

Advancing the marker deliberately on acquisition — one `check_and_advance` at
election time instead of waiting for the first natural write — would collapse the
successor-side half of the race and make the ledger non-zero from the first
election rather than the first write. Worth doing; **not** a precondition, since
the predecessor's self-fencing already bounds divergence by δ.

## Acceptance for the enforce flip

All of these, together — any one alone is the trap:

| signal | required | why |
| :-- | :-- | :-- |
| `ehdb_election_epoch` | **≥ 1** | a token exists at all |
| `ehdb_election_token_valid` | **1**, sustained | it is defensible |
| `ehdb_fencing_writes_checked_total` | **climbing** | the decorator is on the path |
| ⭐ `ehdb_fencing_epoch_advances_total` | **≥ 1** | ⚠⚠ **the discriminator, and a SAFETY gate (see §3).** 0 here with `writes_checked` climbing means the fence received epoch 0 and **cannot ever refuse** — a green fence that does nothing |
| `ehdb_fencing_stale_refused_total` | **0** in steady state | no legitimate writer wrongly fenced |
| `ehdb_fencing_stale_observed_total` | 0 in steady state | with one writer there is nothing stale to see |

⚠ `stale_observed == 0` is evidence **only** alongside a climbing
`writes_checked` **and** a non-zero `epoch_advances`. Alone it is equally
consistent with a decorator nothing reaches.

⚠ Order: `shadow` first, with the #354 wiring live, until `epoch_advances ≥ 1`
is observed. Only then `enforce`. Arming enforce before `epoch_advances` has
moved is arming a fence whose behaviour has never once been demonstrated.

## Rollback

`NOETL_EHDB_FENCING` back to unset (the decorator is then not constructed at
all). One env change, one roll.

⚠ The ledger marker at `shared_root/.fencing` **persists** across the rollback.
That is correct and must not be "cleaned up": the marker is the monotonic
high-water epoch, and deleting it would let a stale epoch be accepted as fresh
the next time enforce is armed.

## Related

- [`ROLLOUT.md`](ROLLOUT.md) — C2's staged roll (does not touch `NOETL_EHDB_FENCING`).
- [`C1-ENUMERATION.md`](C1-ENUMERATION.md) — which mutation paths the fence covers,
  and which are excluded by RWO attachment instead.
