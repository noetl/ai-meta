# Draining the prod non-convergence backlog

**NOT RUN. Blocked on a human merging [server#298](https://github.com/noetl/server/pull/298).**

3258 executions on `shastaratech-noetl-prod` are eligible at the default 24h
grace, the oldest 158.9 days stale. This is the procedure to clear them, written
so the run is mechanical and every step has a stated rollback.

Read `RESULT.md` first — in particular §2 (why the grace floor exists) and §3
(this is historical debt, not an active leak, so the drain is one-time).

---

## 0. Preconditions

| | |
| :-- | :-- |
| server#298 merged, released, image in AR | **not done** — merges are gated to a human |
| `gcloud config get-value account` | `shastaratech@gmail.com` |
| `gcloud config get-value project` | `shastaratech-noetl-prod` (defaults to `shastara` — override) |
| context | `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`, ns `noetl` |
| current server image | record it — this is the rollback target |

```bash
kubectl -n noetl get deploy noetl-server-rust \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

Release + image: follow `agents/rules/release-versioning.md` — merge with a
conventional subject, let semantic-release tag, then `crane copy` GHCR→AR by
digest (`publish-ar` is broken, ai-meta#211). **Do not hand-edit `Cargo.toml`.**

---

## 1. Roll the image with the sweep still OFF

The sweep is default-off, so this step changes no behaviour. Doing it as its own
step means that if anything is wrong with the build, it surfaces *before* the
sweep is ever armed.

```bash
kubectl -n noetl set image deploy/noetl-server-rust \
  noetl-server=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:<digest>
kubectl -n noetl rollout status deploy/noetl-server-rust --timeout=300s
kubectl -n noetl logs deploy/noetl-server-rust | grep nonconvergence
#   expect: "non-convergence sweep: disabled … — not scanning"
```

**Gate:** 0 CrashLoopBackOff, the "disabled" line present, and a synthetic
execution completes with paired evidence (published == projected == all group
cursors, lag 0, `cursor_errors` 0, `out_of_order_appends` 0).

**Rollback:** `kubectl -n noetl set image … @sha256:<recorded prior digest>`.

---

## 2. Record the baseline the drain will be judged against

Not an execution count. The two things that must be true afterwards:

```bash
# a) the exact eligible set, so "did it touch anything else?" is answerable
psql … -At -F'|' -f eligible.sql > /tmp/eligible-before.txt   # SQL: RESULT.md §9
wc -l /tmp/eligible-before.txt        # expect ~3258

# b) the status census
psql … -At -F'|' -c "
WITH s AS (SELECT execution_id FROM noetl.event
           WHERE event_type IN ('playbook.initialized','playbook_started','playbook.started')
           GROUP BY 1)
SELECT count(*) FROM s;"
```

Also record `noetl_nonconvergence_sweep_total` (absent = zero) and the
`playbook.failed` count, so the delta is attributable.

---

## 3. Arm the sweep conservatively

Start at a **cap of 20 per tick** — the default — not the 200 used to drain
kind. At 300s that is ~240/hour, so 3258 takes ~14 hours. That pace is
deliberate: a sweep that clears thousands in one tick is a sweep whose blast
radius nobody can watch.

```bash
kubectl -n noetl set env deploy/noetl-server-rust \
  NOETL_NONCONVERGENCE_SWEEP_ENABLED=true
# grace, interval, cap and stuck-claim all stay at their defaults:
#   86400s / 300s / 20 / 0
kubectl -n noetl rollout status deploy/noetl-server-rust --timeout=300s
kubectl -n noetl logs deploy/noetl-server-rust | grep nonconvergence
#   expect: "ENABLED … grace_secs=86400 max_per_tick=20 stuck_claim_secs=0"
```

⚠ **If the log reports `effective` different from `configured`, stop.** That
means the grace was set below the floor, and the intended configuration is not
what is running.

**Rollback, at any point, instantly:**

```bash
kubectl -n noetl set env deploy/noetl-server-rust NOETL_NONCONVERGENCE_SWEEP_ENABLED=false
```

No state is carried between ticks, so this is complete. Already-emitted
`playbook.failed` events are append-only and stay — they are the intended
outcome, not damage.

---

## 4. Watch the first three ticks before walking away

```bash
kubectl -n noetl port-forward deploy/noetl-server-rust 18082:8082 &
watch -n 30 'curl -s http://127.0.0.1:18082/metrics | grep nonconvergence'
```

Expected after tick 1: `candidate` ≈ scan window, `terminated` = 20,
`capped` = the rest.

### The abort conditions — any one of these, roll back immediately

1. **`terminated` exceeds `20 × ticks`.** The cap is not holding.
2. **Any execution terminated that is not in `/tmp/eligible-before.txt`.**
   This is the negative control and the most important one:
   ```bash
   psql … -At -c "
   SELECT e.execution_id FROM noetl.event e
   WHERE e.event_type='playbook.failed'
     AND e.meta->>'emitted_by'='nonconvergence_sweep'
     AND e.created_at > '<arm time>'" | sort > /tmp/terminated.txt
   comm -23 /tmp/terminated.txt <(sort /tmp/eligible-before.txt)
   #   MUST be empty
   ```
3. **`skipped_live` or `skipped_parent_active` rising alongside `terminated`
   climbing past the eligible count** — the eligible set is moving under the
   sweep, which it should not be.
4. **Any new execution failing.** Fire a synthetic `fixtures/playbooks/hello_world`
   during the drain; it must reach COMPLETED.
5. **Dispatch latency or publish/append throughput moving.** Nothing here
   touches the hot path; movement means something else is wrong.

---

## 5. Completion

The drain is done when `capped` stops rising and `candidate` per tick falls to
the residue (executions inside the grace window, which should be zero — §3 of
`RESULT.md` measured a 0% permanent-stall rate, so no new eligible executions
should appear).

Then **turn the sweep back off**:

```bash
kubectl -n noetl set env deploy/noetl-server-rust NOETL_NONCONVERGENCE_SWEEP_ENABLED=false
```

Leaving it on is a defensible choice later, but not on the first run. It should
be an explicit decision taken after the backlog is clear and the counters have
been read, not a leftover.

Final evidence to record:

- `terminated` total, and that it equals the eligible-before count minus any
  `skipped_*`;
- the set difference in §4.2 is empty;
- paired evidence unchanged (published == projected == cursors, lag 0, 0
  dup/gap/out-of-order/cursor_errors);
- `COMPLETED` count unchanged, `FAILED` up by exactly `terminated`.

---

## 6. What is *not* covered here

- **The `execution.cancelled` projection fix ships in the same image.** 234
  deliberately-cancelled prod executions will flip from `RUNNING` to `CANCELLED`
  the moment step 1 lands, with no sweep involvement and no events written. That
  is a read-path change only, but it will move the status census, so record the
  before/after separately from the drain's.
- **The plaintext-credential exposure** (6247 events, 2665 executions,
  2026-02-26 → 2026-05-29 — see `../223-ehdb-prod-runbook/P8-muno-provenance.md`
  §5). The event log is append-only and never purged, so the drain does not and
  cannot remove it. **Rotating the OpenAI and Anthropic keys is the only
  remediation and is a human action.** It is unrelated to this drain and should
  not be bundled into it.
