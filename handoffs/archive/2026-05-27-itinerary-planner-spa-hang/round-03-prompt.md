---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 3
from: claude
to: codex
created: 2026-05-27T15:25:00Z
status: open
expects_result_at: round-03-result.md
wait_phrase: "proceed with gateway nats fix"
---

# Round 03 — Gateway NATS subscription receives zero messages despite confirmed broker broadcast

> **Predecessors in this thread:**
> `round-01-result.md` (NATS subject mismatch + parser shape) — fixed
> via `noetl/gateway#12` + `noetl/ops#120`, both merged + deployed.
> `round-02-result.md` (outbox publishes arrow-feather, gateway expects
> JSON) — fixed via `noetl/noetl#620`, merged + deployed.  Outbox now
> emits JSON; outbox table exists on cluster; 1231 messages in the
> `NOETL_EVENTS` JetStream stream.  Login works.  SPA still hangs on
> "Muno is planning…".

You are operating in `/Volumes/X10/projects/noetl/ai-meta`.  Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`, `agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose),
`agents/rules/logging.md` (no INFO on hot paths).

Re-read `round-01-result.md` and `round-02-result.md` end-to-end
before starting Phase A.

## Current state of the puzzle

After rounds 01 and 02, the SPA still hangs.  The pipeline is healthy
except for one stubborn break:

- noetl events → noetl.outbox table → JetStream stream `NOETL_EVENTS`
  → 1231 stored messages, retention `limits`, subject pattern
  `noetl.events.>`.  All in-cluster verification confirms publishes
  are landing in the stream.
- A live probe from inside the `noetl` namespace publishing to
  `noetl.events.default.default.gw-probe-test-9999.0` and a fresh
  core NATS subscriber **in the same pod** receives the message
  immediately (proven).  So broadcast from JetStream publish to core
  subscribers works end-to-end inside the broker.
- The gateway pod in the `gateway` namespace connects to NATS at
  startup, logs
  `noetl_gateway::playbook_state: Subscribing to execution lifecycle NATS events: noetl.events.>`
  (`src/playbook_state.rs:21`), and never logs
  `Execution lifecycle NATS subscription ended` (the spawned task's
  shutdown branch).
- Yet **zero** subsequent messages are received: no
  `Failed to parse lifecycle NATS payload` warnings, no successful
  state-message deliveries.  The probe published from noetl-server
  to `noetl.events.default.default.gw-probe-test-9999.0` did NOT
  produce a log line in the gateway's stream.

## Hypotheses (ordered by likelihood, please confirm or rule out)

1. **Silent panic in the tokio spawned task.**
   `tokio::spawn(async move { … })` swallows panics by default; the
   task could have died after the initial `Subscribing` log.  Add
   logging or wrap the closure in `tokio::spawn(async move { … }
   .catch_unwind())` to surface this.

2. **`async_nats::Client::subscribe` does not see JetStream-stream
   publishes when the stream has `retention: limits`.**  This would
   contradict the noetl namespace probe result, but the probe used
   a different async client (Python `nats.py`), and the Rust
   `async_nats` crate's subscribe may treat stream-routed subjects
   differently.  Verify by reading the `async_nats` 0.38 docs +
   trying a JetStream pull/push consumer as an alternative.

3. **NATS account / permission boundary between the `noetl` and
   `gateway` Kubernetes namespaces.**  Both pods connect with
   `nats://noetl:noetl@nats.nats.svc.cluster.local:4222` (same
   user, same broker).  But maybe NATS server config has account
   imports/exports that allow `noetl` namespace to publish + receive
   on `noetl.events.>` but restrict cross-namespace subscribers.
   Audit the NATS server's `accounts` block (cluster-side helm
   chart at `repos/ops/automation/helm/nats/...` or the static
   manifests).

4. **The subscriber's underlying connection dropped silently.**
   `async_nats` should auto-reconnect, but maybe not — and even with
   auto-reconnect, the inflight subscription handle may be stale.

5. **Subscriber's Rust drop semantics.**  If the subscriber handle
   is held only inside the spawned task and the task ever yields
   while NATS is reconnecting, the subscription could be silently
   torn down.

## What Round 03 delivers

The smallest fix that gets gateway delivering `playbook/state` SSE
frames again for newly-published events.  Two plausible shapes:

- **Option A: instrumented core subscriber.**  Add an INFO-level
  log on every received NATS message in `playbook_state.rs` so the
  next round-of-tests pinpoints exactly where the chain breaks.
  Confirm whether messages arrive at all.  If they don't, this
  rules in hypothesis 1, 3, or 4.

- **Option B: switch to JetStream durable pull consumer.**  More
  robust against connection drops + guaranteed delivery semantics
  + replayable on restart.  Bigger change but a real architectural
  upgrade.  The gateway already imports `async-nats`'s JetStream
  surface (used in `request_store.rs`, `session_cache.rs` —
  `K/V bucket` is a JetStream feature), so no new dependency.

Recommended order: ship Option A first (purely additive logging),
deploy it, observe the next user chat turn.  Two outcomes:

  - Messages arrive but parser/forwarder drops them silently → fix
    the right layer in a follow-up.
  - Messages don't arrive at all → ship Option B as the durable
    fix.

## Phases

### Phase A — read-only audit (no cluster mutations, no code changes)

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only
   git -C repos/gateway fetch origin && git -C repos/gateway checkout main && git -C repos/gateway pull --ff-only
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull --ff-only
   ```

2. Re-read `round-01-result.md` and `round-02-result.md`.  Both are
   approved as-is — do not re-litigate.

3. Inspect `repos/gateway/src/playbook_state.rs` end-to-end.  Pay
   attention to:
   - The spawned task's panic-safety.  Is the closure wrapped?
   - The subscriber's lifetime — is the handle held by the task or
     can it be dropped?
   - The connection — is it shared with other subscribers
     (`callbacks.rs`, `session_cache.rs`, `request_store.rs`)?
     If multiple call sites call `connect_nats(...)` separately,
     each gets its own connection; if one drops silently the others
     stay alive.

4. Check the NATS broker's account / permissions config:
   ```
   grep -rn "accounts\|users\|permissions\|publish\|subscribe" \
       repos/ops/automation/helm/nats/ repos/ops/ci/manifests/nats/ 2>&1 | head
   ```
   Confirm whether the `noetl` NATS user has the same subscribe
   permissions in both the `noetl` and `gateway` namespace contexts.
   (Pods in either namespace use the same `nats://noetl:noetl@…`
   URL, so a per-namespace permission would be unusual but worth
   ruling out.)

5. Read the `async_nats` 0.38 changelog and crate docs for any
   known issues with subscribing to a subject that's covered by a
   JetStream stream's `subjects: [...]` config.

### Phase B — code change (Option A first)

6. Branch:
   ```
   git -C repos/gateway checkout -b kadyapam/playbook-state-nats-instrumentation
   ```

7. In `src/playbook_state.rs`, add per-message INFO logging at the
   top of the `while let Some(msg) = subscriber.next().await` loop
   so EVERY received NATS message produces a log line (subject +
   payload byte length).  Move the existing parse-failure WARN to
   stay as-is — but the new INFO log proves whether messages
   arrive at all.

   Also: wrap the spawned task body in something that surfaces
   panics, e.g.:

   ```rust
   tokio::spawn(async move {
       let res = std::panic::AssertUnwindSafe(async move {
           while let Some(msg) = subscriber.next().await { … }
       })
       .catch_unwind()
       .await;
       if let Err(e) = res {
           tracing::error!(?e, "Execution lifecycle NATS subscription panicked");
       } else {
           tracing::warn!("Execution lifecycle NATS subscription ended");
       }
   });
   ```

   Per `agents/rules/logging.md`: INFO logging is acceptable here
   because the message frequency is bounded by playbook lifecycle
   events (not a poll loop).  But cap the payload preview to the
   first 200 bytes to avoid log floods on large payloads.

8. Add a unit test for the parser/forwarder using a synthetic
   `playbook.completed` JSON envelope (no NATS required) so the
   regression coverage stays tight.

9. Run `cargo test playbook_state`.

### Phase C — open draft PR

10. Push + open draft PR on `noetl/gateway`.  Body should explain:
    - The Round 03 puzzle (gateway subscription appears alive but
      receives zero messages).
    - The instrumentation shape (per-message INFO + panic
      surfacing).
    - That this is **diagnostic instrumentation, not the final
      fix** — the next round either confirms Option A is sufficient
      or escalates to Option B (JetStream consumer).
    - Cross-link to the ai-meta handoff rounds 01–03.

11. Write the result file at
    `handoffs/active/2026-05-27-itinerary-planner-spa-hang/round-03-result.md`
    following the prompt's FINAL REPORT spec.  Commit + push.

### Phase D — live re-deploy (GATED)

> ***Run only after explicit human go-ahead. Wait phrase: `proceed with gateway nats fix`.***

12. After the PR merges:
    - Rebuild gateway image off main (the Rust + alpine build is
      ~16 min via Cloud Build).
    - `helm upgrade noetl-gateway` with the new image tag.
    - Have the user trigger one chat turn.
    - Pull `kubectl logs deploy/gateway --since=2m | grep playbook_state`.
    - Report:
      - "messages arriving (count + sample subjects)" → diagnose
        next layer in a follow-up round.
      - "still zero messages → architecture / NATS config issue"
        → escalate to JetStream consumer (Option B).

## Cluster state when this thread starts

- GKE context:
  `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
- noetl: helm rev 175, image
  `inline-runner-v9-20260527074000` (v2.102.8).  Worker on
  `NOETL_INLINE_TRIVIAL_CHILDREN=off`, server + worker on
  `NOETL_EVENT_MIRROR_ENABLED=true`.
- Gateway: helm rev 128, image
  `noetl-gateway:spa-fix-20260526215539` (v2.11.1).
  `NATS_UPDATES_SUBJECT_PREFIX=noetl.events.`.  Pod
  `gateway-dfc9864-flx5s`, freshly restarted at 15:05:09 UTC.
- Outbox: 1231 rows, ALL PUBLISHED.  Subjects of shape
  `noetl.events.default.default.<exec_id>.0`.
- JetStream stream `NOETL_EVENTS`: 1231 messages, `retention: limits`,
  `storage: file`, subjects `[noetl.events.>]`.

## Hard rules

- Do NOT modify the cluster during Phases A–C.
- Do NOT push to main on any repo.
- Do NOT merge any PR yourself.
- Phase D is gated on the wait phrase `proceed with gateway nats fix`.
  If the user has not said it yet, write the result with
  `phase D blocked: awaiting "proceed with gateway nats fix"`.
- No "canonical" in any prose or commit message.
- Do not log at INFO for high-frequency / poll paths.  Per-message
  NATS event INFO is acceptable (bounded by playbook lifecycle).
- Do not store secrets in any file under ai-meta.
- If preconditions are missing, stop and report.

## What success looks like

- Concrete answer to "do messages arrive at the gateway subscriber?"
  with grep-able log fingerprints either way.
- A focused gateway PR (open as draft) with the diagnostic
  instrumentation + a unit test.
- Clear next-action recommendation (Option A sufficient vs Option B
  needed) recorded in the FINAL REPORT.

## FINAL REPORT

Always emit, even on early STOP.  Frontmatter:

```yaml
---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 3
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-03-prompt.md
status: complete | partial | blocked
---
```
