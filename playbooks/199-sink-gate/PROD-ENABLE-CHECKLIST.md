# Enabling the write-behind sink gate in prod — the complete prerequisite list

**NOT ENABLED. Nothing here has been applied to prod.** This exists so that
deciding to enable it is one decision, not a decision followed by three
discoveries.

The gate is what stops the server's Feather result-tier GC reclaiming objects for
executions whose business context has not yet reached the customer's system of
record (noetl/ai-meta#198/#199, the write-behind-cache boundary).

---

## Why this needed a checklist

Enabling it looks like one flag. It is **three** things, and each of the first
two was found only by running the thing and reading the failure:

1. The worker must **emit** the signal → shipped, but it was posting without auth.
2. The user pool must be **able** to reach `/api/internal/*` → it had no token, in
   kind *and* prod.
3. The server must **act** on it → the flag.

Miss any one and the gate is silently starved: `post_sink_state` swallows
failures on purpose (it is bookkeeping for a default-off gate and must never fail
a connector step that has already written to the customer's store), so a
misconfiguration produces a WARN and a counter and an empty
`noetl.sink_pending` — which looks exactly like "no sink steps ran".

---

## The three prerequisites

| # | what | where | state |
| :-- | :-- | :-- | :-- |
| 1 | **Code — emit the signal** | worker#218 (producer) + **worker#221** (the `NOETL_INTERNAL_API_TOKEN` bearer, without which every post 403s) | merged, released **v5.95.2** |
| 2 | **Deployment — the user pool can authenticate** | [ops#246](https://github.com/noetl/ops/pull/246) adds `NOETL_INTERNAL_API_TOKEN` to `noetl-worker-rust` from the existing `noetl-internal-api-token` Secret | **PR open, not merged, not applied to prod** |
| 3 | **The flag** | `NOETL_RESULT_TIER_GC_SINK_GATE=true` on `noetl-server-rust` | unset everywhere |

Prerequisite 2 is the one that bites: sink steps are author-declared on
**ordinary** playbook steps, so they run on the **user pool**, which before
Slice A had no reason to call `/api/internal/*` and correctly carried no token.
The system pool has had one all along, which is why this was easy to miss.

Optionally also `NOETL_SINK_GATE_EVICTION=true` on the workers — that gates the
worker's own durable-segment GC on the same signal. Independent of the server
gate; both default off.

---

## Order, and why

1. **Roll the worker image** (≥ v5.95.2). Inert on its own — the posts start
   flowing but the server's gate is still off, so nothing changes behaviour.
2. **Merge + apply ops#246.** Also inert. Now the posts stop 403-ing and
   `noetl.sink_pending` starts receiving marks and confirms.
3. **Verify the feed is alive before flipping anything**, which is the step that
   makes this safe:
   ```sql
   -- during a run that includes a `sink: true` step
   SELECT count(*) FROM noetl.sink_pending;
   ```
   plus `noetl_worker_sink_state_post_total{outcome="ok"}` moving. If `ok` is
   flat and `http_error` is climbing, prerequisite 2 has not taken effect —
   **stop here**, because the gate would be enabled over an empty feed and would
   retain nothing while appearing healthy.
4. **Only then** set `NOETL_RESULT_TIER_GC_SINK_GATE=true` on the server.

Steps 1–3 are all reversible and behaviour-neutral. Step 4 is the only one that
changes GC behaviour, and it reverts by unsetting the flag.

---

## How to tell it is actually working

The trap, which cost a test run: **`mark` and `confirm` are a pair.** A
*successful* sink step adds the row and then removes it, so sampling
`noetl.sink_pending` after the execution finishes shows an empty table whether
the gate works perfectly or is completely unwired.

Sample **during** a run with a slow sink step, and prefer the **server-side**
counter:

```
# SERVER — one endpoint, pool-independent. Watch this first.
noetl_sink_state_total{op="mark"}                                   must move
noetl_sink_state_total{op="confirm"}                                must move

# WORKER — corroborating only. Per-pod and in-memory, and the user pool
# autoscales, so the pod that ran the step may be gone before you scrape it.
noetl_worker_sink_state_post_total{action="mark",outcome="ok"}      should move
noetl_worker_sink_state_post_total{outcome="http_error"}            must stay 0
```

The two together localise a failure without guesswork: worker `ok` rising while
server `mark` stays flat means the posts are not arriving; worker `http_error`
rising means prerequisite 2 has not taken effect; both flat means no sink step
ran at all. Reading only the worker side is what cost a run — those counters die
with the pod.

A non-sink step must leave the feed untouched — if everything marks, the
retention the gate produces means nothing.

---

## What is still NOT covered

- **Slice C's platform-automatic sink** is observe-only; `NOETL_AUTOSINK_TARGET`
  is read, stored, logged and never acted on (deliberately, and its module doc
  says so). Enabling the gate does not change that.
- The gate protects the **Feather result tier**. The permanent `noetl.event` log
  is a separate boundary — see noetl/ai-meta#195 and the 461 MB measurement.
