---
thread: 2026-09-23-cmdbus-writer-tier-stall
round: 1
from: claude-opus-5-cloud
to: claude
created: 2026-09-23T20:40:00Z
in_reply_to: round-01-prompt.md
status: partial
---

# Round 01 result — Phase A was already done; Phase B's prod half is blocked; the code half contradicts the brief's mechanism

**Headline: the brief's central mechanism claim is wrong.** The tier service and
the command bus **share no lock**. `tier_store` uses `ehdb_reference` and a
per-path `tokio::sync::RwLock`; the buses use `ehdb_l0::L0Engine` behind a
`std::sync::Mutex`. They are disjoint. What couples them is the **shared Tokio
runtime**, which both subsystems block: the tier store does multi-GB synchronous
file replay on runtime worker threads with no `spawn_blocking`, and the `:9102`
metrics handler parks a runtime thread on a blocking `std::sync::Mutex`.

Two further corrections below (the `health` comparison proves less than claimed;
`ehdb_l0_durability_sample_ok 0` does not mean what its HELP text says), and one
finding that flips the Phase B question: **the noetl/ai-meta#315 cap is already
implemented and enabled by default in `noetl/server` HEAD**, which makes a
steady 19 cmd/min hard to reconcile with re-drives of a fixed execution set.

## Phase A — land the worker-wiki page

**Status: already complete before this round started. No action taken, none needed.**

The brief's premise — that the page "could not be pushed from the cloud session"
and needs a workstation — does not hold. Two things are both true and were
conflated: `add_repo` does refuse `noetl/worker.wiki`, but the session's git
proxy serves anonymous reads of public repos directly, and **the content was
already pushed on 2026-09-22.**

Evidence:

```
$ git clone --depth 1 https://github.com/noetl/worker.wiki.git wikitest
Cloning into 'wikitest'...
EXIT=0

$ git -C wikitest log -1 --format='%H %ad %s' --date=iso
0e50d644ceeea5945cff49f2ea995f7aa92152e1 2026-09-22 19:34:43 +0000 docs: cmdbus-writer tier service, the engine lock, and the probe gap

$ ls wikitest
Home.md  _Sidebar.md  cmdbus-writer-tier-service.md  deployment-specification.md
nats-mcp-tool-kinds.md  noetl-executor-adoption.md  release-pipeline.md  worker-credentials.md
```

The live wiki commit carries the patch's exact subject and author date
(`Tue, 22 Sep 2026 19:34:43 +0000`, `worker-wiki-f4a41ea.patch` line 3-5).

Proof the patch is applied, not merely similar — reverse-apply succeeds on all
four files:

```
$ git apply --check          .../worker-wiki-f4a41ea.patch
error: patch failed: Home.md:51
error: Home.md: patch does not apply
error: patch failed: _Sidebar.md:12
error: _Sidebar.md: patch does not apply
error: cmdbus-writer-tier-service.md: already exists in working directory
error: patch failed: deployment-specification.md:106
apply-check exit=1

$ git apply --check --reverse .../worker-wiki-f4a41ea.patch
reverse-check exit=0
```

And `diff attachments/cmdbus-writer-tier-service.md wikitest/cmdbus-writer-tier-service.md`
→ **IDENTICAL**.

**Resulting wiki SHA: `0e50d644ceeea5945cff49f2ea995f7aa92152e1`.**

⚠ **The landed page now needs a correction**, because it states the mechanism
this round disproves (see Phase B):

- `cmdbus-writer-tier-service.md:1` — title *"the tier service and the engine lock"*
- `cmdbus-writer-tier-service.md:16` — *"it **takes the engine lock**"*
- `cmdbus-writer-tier-service.md:102` — *"`0` = the scrape could not take the engine lock"*

Line 102 is wrong as a matter of code (see Correction 2). The title/line-16
framing attributes the tier stall to a lock the tier service never touches. This
is a `representation-drift.md` instance in a doc written *by* that rule — filed
below under **Manual escalation needed**.

## Phase B — identify the source of the ~19 cmd/min

### Steps 5, 6, 7 — BLOCKED, no cluster access

Established, not assumed:

```
$ for t in kubectl gcloud helm kind; do command -v $t || echo "$t NOT FOUND"; done
kubectl NOT FOUND
gcloud  NOT FOUND
helm    NOT FOUND
kind    NOT FOUND
$ echo "KUBECONFIG=${KUBECONFIG:-<unset>}"
KUBECONFIG=<unset>
$ ls -la ~/.kube ~/.config/gcloud
ls: cannot access '/root/.kube': No such file or directory
ls: cannot access '/root/.config/gcloud': No such file or directory
```

No `kubectl`, no `gcloud`, no kubeconfig, no GKE credentials for
`noetl-prod-autopilot` / `shastaratech-noetl-prod`. **No numbers were re-measured
and none are invented.** Every figure quoted from the brief below is carried
as-of **2026-09-22** and is *not* fresh.

The question in step 7 — *are these re-drives of stuck executions, or legitimate
periodic system work?* — **is not answered by this round.** What follows is a
sharper and cheaper way to answer it than sampling command records.

### A finding that changes step 6's method — #315's cap already shipped

The brief cites noetl/ai-meta#315 as *"no attempt cap, no eviction, unbounded
orch_cache growth"*. That is the **issue's description, not the code**. On
`noetl/server` HEAD (`35c45182`) the cap is implemented and **on by default**:

- `src/handlers/events.rs:2982` — `let cap = state.config.reconcile_max_noops;`
- `src/handlers/events.rs:2788` — `pub(crate) fn reconcile_decision(advanced: bool, noops_before: u32, cap: u32) -> (u32, bool)`
  — any progress resets the budget; `cap == 0` disables it entirely ("the
  pre-fix behaviour and the negative control the tests need").
- `src/handlers/events.rs:3000-3001` — `record_reconcile_giveup("max_noops")` then `state.orch_cache.evict(execution_id)`
- `src/config/app.rs:1004` — `fn default_reconcile_max_noops() -> u32 { 225 }`
- `src/handlers/events.rs:2900` — `const RECONCILE_INTERVAL: Duration = Duration::from_secs(8)`

**225 × 8s = 30 minutes.** So on a server running this build with the default,
a permanently-stuck execution stops being re-driven ~30 minutes after it
stalls, and is evicted.

**That yields a falsifiable prediction the brief's own data already strains.**
The measured arrival rate was *flat* across 1h43m:

```
17:35:09   appends 4823   committed 109334   system lag 455
19:18:37   appends 6784   committed 111159   system lag 606
arrivals 0.3159/s = 19.0 cmd/min      (as-of 2026-09-22, NOT re-measured)
```

A fixed set of stuck executions re-driven under a live 225-poll cap would
**decay to zero inside ~30 minutes**, not hold flat for 103. So *if* the
deployed server carries this build with a non-zero cap, the steady rate is
**inconsistent** with re-drives of a fixed set, and points at either legitimate
periodic work or a continuously-replenished set of executions.

⚠ This is a conditional, not a conclusion — it turns on three prod facts I
cannot read. The decisive checks, which are far cheaper than sampling command
records:

1. **`NOETL_RECONCILE_MAX_NOOPS` on the deployed server.** `0` disables the cap
   and restores pre-fix behaviour exactly. If it is `0`, the re-drive hypothesis
   is live again and everything above is void.
2. **Does the deployed server build contain the cap at all?** `git log` the
   server pointer against `src/handlers/events.rs:2982`.
3. **`noetl_reconcile_giveup_total{reason="max_noops"}`** on the server's
   `/metrics` (`src/metrics.rs:216`). Non-zero and climbing = the cap is firing,
   i.e. re-drives are real *and* being bounded. Zero with a live cap = nothing is
   hitting it.
4. **`noetl_orchestrate_in_flight_executions`**,
   `noetl_orchestrate_in_flight_stale_executions`,
   `noetl_orchestrate_in_flight_oldest_seconds` (`src/metrics.rs:3624`, `:3654`,
   `:3676`) — the #447 guard population, published every 8s.

⚠ Fingerprint worth knowing before trusting check 3: `src/metrics.rs:248-268`
records that **v3.99.3 shipped the giveup counter on
`prometheus::default_registry()` while `gather_text()` gathers this crate's own
`registry()`** — "the cap worked and the counter proving it was invisible". A
zero there must be read against the running version, not taken at face value.

### Step 8 — why `read_execution` costs ~5.6s and `health` costs 0.38ms

This is answered, from code. Sources: `noetl/worker@adcc64f`,
`noetl/ehdb@698af0e` (tag `v0.3.1`, matching the worker's `Cargo.lock` pin).

#### Correction 1 — the `health`-vs-`read_execution` comparison does not show what the brief says

The brief calls this "the finding": *"`health` at 0.38ms beside `read_execution`
at 5.6s, same process and listener, is the finding: the control path is instant,
the data path is contended."* The measurement is real; the inference does not
follow, for two independent reasons.

**(a) The measured window excludes everything `health` would have to wait for.**
`src/ehdb/tier_service.rs:591-599`:

```rust
let started = std::time::Instant::now();
let req = decode_request(&payload);
let (resp, obs) = encode_response_observed(&req).await;
let elapsed = started.elapsed().as_secs_f64();
```

The permit is acquired **before** this, in the accept loop
(`tier_service.rs:842`, `serve_conn(stream).await` under `let _permit = permit`),
and the frame read is deliberately outside the window. So a `health` request that
queued 999ms for a permit still records ~0.38ms. And one that fails to get a
permit within `shed_after` is **shed at `tier_service.rs:847` and recorded under
`conn`/`shed_busy`, never under `health` at all.** The `health` series is
structurally incapable of showing saturation.

**(b) `health` contains no await point, so it cannot observe runtime starvation.**
`tier_service.rs:366`, `TierRequest::Health`, is a `format!` over a constant —
it takes no lock, touches no store, and never yields. `read_execution` yields at
least at the lock acquire, so its wall-clock `elapsed` includes **time the task
spent descheduled**. The two numbers differ for at least three reasons that this
pair of series cannot separate: genuine work, lock waiting, and runtime
starvation.

The 5.6s is nonetheless *not* permit-queueing — that much the window does
establish. The rest follows.

#### The actual cost of `read_execution`

`src/ehdb/tier_store.rs:627-641`:

```rust
pub async fn read_execution(...) -> TierStoreOutcome {
    ...
    let lock = store_lock(cfg, tier);
    let _shared = lock.read().await;          // tier_store.rs:639
    read_execution_locked(cfg, tier, execution_id)   // tier_store.rs:640 — SYNCHRONOUS
}
```

`read_execution_locked` (`tier_store.rs:643`) is a plain `fn`. **It runs to
completion on the Tokio worker thread.** In order it does:

1. **A shared read on `store_lock`** (`tier_store.rs:163`, a `tokio::sync::RwLock`
   keyed by store path). Appends take it **exclusively** —
   `tier_store.rs:410` and `:464`, `let _exclusive = lock.write().await;`. With
   `append` at 2.217s mean / ~18.1s tail (as-of 2026-09-22) every read on the same
   tier queues behind in-flight appends. This is real contention — but it is the
   *tier's own* RwLock, not the engine lock.

2. **`segments_possibly_holding`** (`tier_store.rs:893`) → a `read_dir` per call,
   then for each sealed segment `load_segment_index` (`tier_store.rs:795`):

   ```rust
   let raw = std::fs::read_to_string(segment_index_path(segment)).ok()?;
   Some(raw.lines().map(str::trim).filter(...).map(|l| l.to_string()).collect())
   ```

   **Uncached, per read.** A blocking whole-file read plus one `String`
   allocation per execution id, rebuilding a `HashSet<String>` every single
   `read_execution`. The code's own comment measures a production segment at
   **82,906 lines** (`tier_store.rs:830` doc block). That is ~83k allocations per
   sealed segment per read, on a runtime thread.

3. **If any index matches** → `read_execution_across_segments`
   (`tier_store.rs:1011`), which per matching segment constructs a
   `LocalReferenceEventLogDriver` and calls `read_execution`, i.e. **replays the
   segment in full** into memory, then `ehdb_reference::forget_runtime(path)`
   (`tier_store.rs:925-947`). The code's own comment names production's sealed
   segments as **1.08 GB and 3.3 GB**.

4. Then the active segment, likewise.

**There is exactly one `spawn_blocking` in the entire file** — `tier_store.rs:713`,
inside `spawn_index_build`, i.e. the off-request index backfill. Every data path
(`append_locked:535`, `append_batch_locked:469`, `read_execution_locked:643`,
`scan_locked:1080`) is synchronous on the runtime.

This is the answer to the brief's "blocking I/O on the async runtime" question:
**yes, on every tier data operation, up to `max_inflight` concurrently.**

#### Correction 2 — the tier service does NOT take the engine lock

The brief: *"**The coupling to everything else is the engine lock.**"* This does
not hold.

```
$ grep -n 'ehdb_l0\|L0Engine' src/ehdb/tier_store.rs src/ehdb/tier_service.rs
tier_store.rs:21://! that small: one engine, one serialised-append critical section, N files.
tier_store.rs:175:/// One engine for every tier.
tier_store.rs:211:/// The tier is **not** an L0 engine, so it has none of the part-sealing ...
tier_store.rs:426:/// Durability and ordering are unchanged: the engine writes the records ...
```

Comments only — **no type, no import, no call**. `tier_store.rs:48-53` imports
from `ehdb_reference` and `tokio::sync::RwLock`. `tier_store.rs:211` says it
outright: *"The tier is **not** an L0 engine."* The L0 engine lock belongs to the
command/event bus (`ehdb-feed`); the tier's lock is a separate `RwLock` keyed by
file path. **Disjoint.**

#### What actually couples the tier stall to the buses and to the server

The shared **Tokio runtime**. `src/main.rs:11` is a bare `#[tokio::main]` —
multi-threaded, `worker_threads` = available parallelism. All faces (command bus
ingest/claim/lag, event bus, tier service, metrics) run in that one runtime, and
two distinct mechanisms occupy its worker threads:

1. **Tier data ops**, as above: synchronous file replay, no `spawn_blocking`, up
   to `NOETL_EHDB_TIER_MAX_INFLIGHT` (4 in prod) at once.
2. **Blocking `std::sync::Mutex` acquisitions inside async tasks**, which *park*
   an OS thread rather than yielding it.

If the writer's `available_parallelism()` is small — plausible on Autopilot, and
the brief measures it at ~0.9 cores — then **4 concurrent blocking tier ops can
occupy the entire worker pool**, and nothing else in the process runs. That
explains the brief's paired-sample correlation (writer 20.006s / gateway 51.311s,
17:07:17) without any shared lock.

⚠ **The measurement that would confirm this is the runtime's worker-thread count**,
which I cannot read. It is the single highest-value prod datum for the next round.

#### The `:9102` metrics handler — takes the lock, is NOT cancellation-aware

`src/command_bus.rs:393-407`, the two closures passed to `serve_writer_metrics`:

```rust
move || {
    integrity_engine.engine().lock().ok().map(|e| e.metrics().snapshot())   // :393-397
},
move || {
    let engine = durability_engine.engine();
    let e = engine.lock().ok()?;                                            // :401
    let mut out = ehdb_feed::render_unreplicated(&e.unreplicated_snapshot());
    out.push_str(&ehdb_feed::render_replicated_lag(&e.metrics()));
    Some(out)
},
```

`engine()` returns `Arc<Mutex<L0Engine<D>>>` where `Mutex` is
**`std::sync::Mutex`** — `ehdb-feed/src/lib.rs:57` (`use std::sync::{Arc, Mutex};`)
and `:500`. So:

**Correction 3 — `ehdb_l0_durability_sample_ok 0` does not mean "could not
acquire the engine lock".** `std::sync::Mutex::lock()` **blocks**; `.ok()` maps
only `PoisonError` → `None`. The gauge therefore reads `0` **only when the mutex
is poisoned** (a thread panicked holding it) — never on contention. Both the
HELP text (`command_bus.rs:438`, `event_bus.rs:524`) and the source comment
(*"On a contended engine lock the provider yields `None`"*, `command_bus.rs:590-594`)
state a property the code does not implement. The brief inherits this, and so
does the published wiki page at line 102.

The operational consequence is the opposite of what the comment intends: on a
contended lock the scrape does not degrade to `sample_ok 0` — it **blocks a
Tokio worker thread until the lock is free.**

**Cancellation: no.** `serve_writer_metrics` (`command_bus.rs:553`) spawns a
detached task per connection:

```rust
tokio::spawn(async move {
    let mut scratch = [0u8; 1024];
    let _ = sock.read(&mut scratch).await;          // :582
    let mut body = ehdb_feed::render_snapshot(&lag());
    body.push_str(&resume);
    if let Some(m) = integrity() { ... }             // blocking lock
    match durability() { ... }                       // blocking lock
    let _ = sock.write_all(resp.as_bytes()).await;   // :613 — result discarded
});
```

Nothing links the client's socket to the task; there is no `select!` on
disconnect. **A client that times out at 3s leaves the task running**, still
queued on the engine mutex, and its answer is written to a dead socket and
dropped at `:613`. The same holds for the tier service:
`read_execution_locked` is synchronous, so once entered it has **no cancellation
point at all**, and `serve_conn` never checks whether the peer is still there.

That is directly visible in the brief's own numbers: **`write_error=901` of
`accepted=10656`** — 8.5% of accepted tier connections did the *full* work and
then found nobody to give it to (`tier_service.rs:631`,
`record_conn("write_error", false, true)`). Each held a permit throughout.

#### What `NOETL_EHDB_TIER_MAX_INFLIGHT` actually bounds

It bounds **concurrent `serve_conn` calls** — connections doing work — acquired
*after* `accept` (`tier_service.rs:826-849`). Specifically:

- `permits = Semaphore::new(limit)`; `waiters = Semaphore::new(limit * TIER_MAX_WAITERS_MULTIPLE)` (prod: 4 and 32).
- `shed_waiters_full` — `waiters.try_acquire_owned()` failed: too many accepted-but-unstarted connections.
- `shed_busy` — `tokio::time::timeout(shed_after, permits.acquire_owned())` expired; prod `shed_after_ms=1000` (`tier_service.rs:847`).
- `write_error` — **not a shed**. The work completed and the reply could not be delivered (`tier_service.rs:631`).

`TierClient` is **connect-per-request** (`tier_client.rs:241`,
`TcpStream::connect` inside `request_within`), one request per connection, so a
permit is not held across idle keep-alive time. But because the work is
synchronous and uncancellable, **a permit is held for the full duration of work
whose client has already given up** — which is what makes `shed_busy=805` and
`write_error=901` co-occur while the brief's average inflight utilisation reads
only ~41%. That average is a scrape-interval mean; during a stall the pool is at
100% and shedding. ⚠ **The brief's inference that "the earlier worry that new
workers would merely convert into `shed_busy` was overstated" rests on that
average and should not be relied on.**

#### Is there a cheap path to serve `ehdb_feed_subject_lag` alone?

**Yes — and it is straightforward, not structural. The cheap data source already
exists and is already lock-free.**

The lag snapshot is served from a background sampler, not from the engine
(`command_bus.rs:356-371`): an `AtomicU64` gauge, an `AtomicU64` committed
cursor, and a `std::sync::Mutex<Vec<SubjectLag>>` refreshed every 2s. The
`lag()` closure (`command_bus.rs:383-391`) touches **no engine lock**. The only
reason a `:9102` scrape can block is that `serve_writer_metrics` renders the
integrity and durability closures into the same response body.

Three fixes, in increasing scope, all small:

1. **Integrity needs no lock at all.** `ehdb-feed/src/lib.rs:290-322` clones the
   engine's metrics `Arc` at construction (`:317`, `let metrics = engine.metrics();`)
   and exposes it at `:506` as `pub fn metrics(&self) -> &Arc<L0Metrics>` —
   documented *"without taking the engine lock (noetl/ehdb#345)"*, and already
   used lock-free at `command_bus.rs:242`. So
   `integrity_engine.engine().lock().ok().map(|e| e.metrics().snapshot())`
   (`:393-397`) becomes `Some(integrity_engine.metrics().snapshot())`.
   **One line; identical data; zero lock.**

2. **Durability should `try_lock()`, not `lock()`.** The work under the lock is
   trivial — `unreplicated_snapshot()` is `self.unreplicated.snapshot()`
   (`ehdb-l0/src/engine.rs:1583`), a small per-shard read. **The cost is entirely
   the wait, not the work.** Switching `:401` to `try_lock().ok()?` makes the
   scrape non-blocking *and* makes `ehdb_l0_durability_sample_ok 0` finally mean
   what its HELP text has claimed all along. Correction 3 becomes a fix rather
   than a doc change.

3. With 1 and 2, `/metrics` never blocks on the engine, and no separate endpoint
   is needed. A dedicated lag-only port is available as a fallback but is not
   required.

⚠ Both touch `event_bus.rs` identically (`:524-532`, `:598`, `:608`) — the event
bus carries the same two closures and the same defect.

## Phase C — mitigation

**Not run. Correctly gated and the wait phrase `ship the writer change` was not
given.** No prod state was read or mutated; no manifest was rendered, diffed or
applied; no restart, replica or `NOETL_EHDB_TIER_MAX_INFLIGHT` change was
proposed for execution.

⚠ **The lever-selection question in step 9 is not yet answerable**, and this
round narrows it rather than settling it. Note also that step 9's framing
("re-drives → #315; legitimate → +1 system-pool replica") is now **incomplete**:
the tier stall has a third, independent cause — the runtime-blocking described
above — which neither lever addresses. Adding a system-pool replica increases
tier concurrency demand against a `max_inflight` of 4 whose permits are held by
uncancellable work.

## Issues observed

1. **The brief's central mechanism is wrong.** "The coupling to everything else
   is the engine lock" — the tier service never takes the engine lock. Evidence:
   `tier_store.rs:48-53` (imports), `tier_store.rs:211` ("The tier is **not** an
   L0 engine"), and a `grep` for `ehdb_l0|L0Engine` across `tier_store.rs` +
   `tier_service.rs` matching comments only.

2. **`ehdb_l0_durability_sample_ok` is a decorative metric.** `.lock().ok()` on a
   `std::sync::Mutex` yields `None` only on poisoning. Its HELP string
   (`command_bus.rs:438`, `event_bus.rs:524`), its source comment
   (`command_bus.rs:590-594`), the brief, and the published wiki page
   (`cmdbus-writer-tier-service.md:102`) all assert contention-detection that the
   code does not implement. `representation-drift.md`'s "what forces this to
   agree with reality?" — nothing does.

3. **`health` cannot observe tier saturation** and should not be cited as
   evidence of one. The permit is taken before the measured window
   (`tier_service.rs:842` vs `:591`); shed health probes are recorded under
   `conn`, not `health`; and `TierRequest::Health` (`:366`) has no await point.

4. **All tier data operations block the Tokio runtime.** One `spawn_blocking` in
   `tier_store.rs`, at `:713`, on the off-request index backfill. `append_locked`,
   `append_batch_locked`, `read_execution_locked`, `scan_locked` are synchronous.

5. **`load_segment_index` has no cache** (`tier_store.rs:795`). A whole-file
   blocking read plus ~83k `String` allocations per sealed segment, on **every**
   `read_execution`. The index exists to avoid replaying segments; it is itself
   re-read per request.

6. **The `:9102` handler is not cancellation-aware** (`command_bus.rs:575-614`).
   A client timing out at 3s leaves the task blocked on the engine mutex; the
   response is written to a dead socket and discarded at `:613`.

7. **`noetl/ai-meta#315`'s cap is implemented and defaults to on** (`events.rs:2982`,
   `:2788`, `config/app.rs:1004` = 225; 8s interval = ~30 min). The brief cites the
   issue title as if it described current code. The issue body is stale.

8. **The published wiki page repeats findings 1 and 2** and needs a correction
   commit (`cmdbus-writer-tier-service.md:1`, `:16`, `:102`).

9. **Not investigated:** "something is speaking HTTP to the binary tier port"
   (`0x47455420` = `"GET "`). No in-repo scraper of `:9110` was found —
   `grep '9110'` across `src/` and `ci/` returns only `tier_client.rs` address
   parsing and tests. It is most likely an external prober or a misrouted
   ServiceMonitor; identifying it needs cluster access.

## Manual escalation needed

**Needs ordinary GitHub credentials (this session has anonymous read only):**

- **Correct `noetl/worker.wiki@0e50d64`** for findings 1 and 2 — retitle away from
  "the engine lock", fix line 16's mechanism, and fix line 102's reading of
  `ehdb_l0_durability_sample_ok`. Required by `change-documentation.md`; the page
  is live and wrong now.
- **Correct the body of noetl/ai-meta#351** — it carries the engine-lock
  mechanism.
- **Update noetl/ai-meta#315** to record that the cap shipped and is default-on,
  so the next reader does not plan against the issue title.

**Needs GKE access to `noetl-prod-autopilot` / `shastaratech-noetl-prod`:**

- The **writer's Tokio worker-thread count** (and its CPU request/limit). Highest-
  value single datum: it decides whether `max_inflight=4` can starve the runtime.
- `NOETL_RECONCILE_MAX_NOOPS` on the deployed server, and whether that build
  contains `events.rs:2982`.
- `noetl_reconcile_giveup_total{reason="max_noops"}` — read against the running
  version, per the `metrics.rs:248-268` registry bug.
- `noetl_orchestrate_in_flight_executions` / `_stale_executions` / `_oldest_seconds`.
- Phase B steps 5-7 in full: the two ≥10-min `:9102` scrapes with **per-subject**
  `ehdb_feed_subject_lag`, and whether the same `execution_id`s recur.

**Needs a human decision (Phase C, wait phrase `ship the writer change`):**

- Whether to ship fixes 1 and 2 from *"Is there a cheap path"* above (lock-free
  integrity; `try_lock` durability) to `noetl/worker` `command_bus.rs` **and**
  `event_bus.rs`. Small, testable, and they remove the `/metrics`-blocks-on-engine
  path outright.
- Whether to wrap the tier store's synchronous paths in `spawn_blocking`. Larger,
  and it interacts with `max_inflight` semantics — should be its own issue, not a
  Phase C action.

⚠ **Nothing in this result is a fresh production measurement.** Every prod number
quoted is the brief's, as-of 2026-09-22.
