# Foca adoption + the embedded command bus — design

**DESIGN ONLY. No code. Both hard-held.** 2026-09-09. Refs ai-meta#332.

These are two separate gates that are easy to conflate because both are
"the next big embedded step". They have different risk profiles and should not
ship together.

---

# Part 1 — Foca adoption (membership → D8)

## Where it stands

`ehdb-gossip` exists and is healthy: builds, **11 tests pass**, covering
`ShardIdentity` (incarnation, address conflict), `MembershipSink` (every
notification kind mapped deliberately), and `GossipOrigin` (an unconfigured
cluster trusts no remote membership; there is deliberately **no permissive
constructor**).

⚠ It has **zero consumers**. That is correct today — it is inert by design — but
it means the crate has never been driven by a real `foca::Foca` runtime. Every
test exercises our adapters, not the integration.

## What adoption actually requires

Foca is "bring your own everything": no I/O, no timers, no identity. The
integration is four pieces, and only the first is written:

| piece | state |
| :-- | :-- |
| `Identity` / notification sink / op authorisation | ✅ built + tested (`ehdb-gossip`) |
| **Transport** — UDP or TCP datagram send/receive per `foca::Runtime` | ✗ |
| **Timer driver** — foca requires the host to schedule its own timer events | ✗ |
| **D8 append path** — every membership transition appended to `RuntimeDataset` | ✗ |

## The design

- **Transport**: UDP within the cluster, one socket per pod, peers discovered
  from the D8 projection (bootstrap) and thereafter from gossip itself. No
  external discovery service — that is the self-sufficiency rule: the *state* is
  ours, the *library* is a dependency.
- **Timers**: a single `tokio` task owning the `Foca` instance, driving
  `handle_timer` off a delay queue. ⚠ Foca is **not** `Sync`; it must live on one
  task and be reached by message passing, not shared behind a lock.
- **D8**: `MembershipSink` already maps each notification to an intended
  transition. Adoption wires those to `RuntimeStore::append` through the
  validated `OpOrigin` seam — which is why append-time validation was built
  first.

## ⚠ The risk that decides the rollout shape

A membership protocol's failure mode is **not** a crash. It is a *plausible
wrong answer*: a node declared dead that is alive, under load or partition. That
evicts a healthy shard and, under embedded per-shard state, takes its data with
it until it rejoins.

So adoption ships **observe-only first**: gossip runs, transitions append to D8,
and **nothing consumes D8 for routing**. Ownership continues to come from the
static shard config. Only after D8 and the static config have been observed to
agree over a long window does anything read D8 for routing.

That ordering is the whole safety argument, and it is the one an "it works in
kind" demo would skip.

---

# Part 2 — The embedded command bus (D2)

## Why it is separate

The event log (D1) is append-and-read. The command bus is **claim/ack with
at-most-once delivery semantics** — a queue, not a log. Embedding it changes how
workers get work, which is the single most load-bearing path in the platform.
The 2026-09-09 incident degraded dispatch for ~40 minutes without touching this.

## What it unblocks

The KEDA autoscaler currently scales on `ehdb_feed_subject_lag` served by the
**cmdbus writer** — the component embedding removes. The replacement series
(`noetl_cmdbus_subject_lag`, pinned unconditionally) can only be produced once
the server embeds the feed. See
[`keda-retarget-embedded-backlog.md`](keda-retarget-embedded-backlog.md).

⇒ **Ordering is forced**: embedded command bus → series with its producer →
side-by-side comparison → KEDA retarget → only then retire the writer.

## The hazard specific to a queue

D1's shadow could be compared by counting appends. **A command bus cannot be
shadowed that way.** Running a shadow claim loop alongside the real one either
double-delivers commands (if it acks) or proves nothing (if it does not).

The workable shape is a **passive** shadow: the embedded feed observes the same
command stream and reports what it *would* have delivered, comparing that
against what the real bus did — never claiming, never acking. That is a
different and more intricate comparator than the event-log one, and it should be
designed before any code.

## Ordering against everything else

The command bus should land **after** the serve flip for D1, not before. D1's
flip is reversible while Postgres stays authoritative; a command bus mistake is
a dispatch outage, which is what this program has already demonstrated it can
cause by accident.
