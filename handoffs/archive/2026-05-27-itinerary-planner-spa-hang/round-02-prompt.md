---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 2
from: claude
to: codex
created: 2026-05-27T07:19:08Z
status: open
expects_result_at: round-02-result.md
wait_phrase: "proceed with outbox JSON fix"
---

# Round 02 — outbox publishes arrow-feather, gateway expects JSON

> **Predecessor:** `round-01-result.md` in this thread.  That round
> identified the NATS subject mismatch + the gateway parser shape.
> Those fixes shipped as `noetl/gateway#12` + `noetl/ops#120` and are
> deployed.  This round picks up where round-01 stopped: events now
> reach the gateway on the right subject, but they're encoded in a
> format the gateway can't parse.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`.  Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`, `agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose),
`agents/rules/logging.md` (no INFO on hot paths).

Re-read `handoffs/active/2026-05-27-itinerary-planner-spa-hang/round-01-result.md`
end-to-end.  Its background section is approved; do not re-litigate.

## New blocker (since round-01)

The travel SPA still hangs at `Muno is planning…` on every chat turn.
The outbox table now exists on the GKE cluster
(`noetl-demo-19700101`) and is receiving events — 438 PUBLISHED rows
captured live.  The gateway is subscribed to the corrected subject
prefix (`noetl.events.`) and its parser correctly extracts the
exec_id from the `{tenant}.{org}.{exec_id}.{shard}` tail.  Yet the
gateway logs 438 occurrences of:

```
WARN noetl_gateway::playbook_state src/playbook_state.rs:30
Failed to parse lifecycle NATS payload as JSON
subject="noetl.events.default.default.<exec_id>.0"
```

**Zero `playbook/state` messages reach the SPA.**

## Root cause

`noetl/core/outbox.py::publish_outbox_batch` (lines 170–181) picks
the published payload as follows:

```python
if subject and payload_bytes:
    await event_publisher.ensure_connected()
    await event_publisher._publish_event_payload(subject, bytes(payload_bytes))
else:
    await event_publisher.publish_event(payload)
```

When `payload_bytes` is present in the outbox row it sends those
raw bytes over NATS (which is the **arrow-feather** encoded form per
`payload_codec`).  Only when `payload_bytes` is NULL does it fall
through to `publish_event(payload)` which JSON-encodes the JSONB
`payload` column.

`enqueue_outbox` (lines 61–83) **always** populates `payload_bytes`
via `rows_to_arrow_feather([payload])`.  So every outbox row goes
out as arrow-feather, and the gateway — built around
`serde_json::from_slice::<Value>` at
`repos/gateway/src/playbook_state.rs:29` — cannot parse it.

The `_mirror_events` direct-publish path
(`repos/noetl/noetl/server/api/core/events.py:49`) uses
`publish_event(payload)` which DOES JSON-encode.  Captured live
gateway logs show ZERO successful parses, which suggests this path
either is not firing for the events the gateway needs, or its
JSON publishes are being shadowed by the arrow-feather ones on the
same subject.  Both behaviors are plausible from the source; only a
live trace can pin which.

## What Round 02 delivers

1. Decide between two fix shapes, both small.

   - **Option A (preferred, smallest):** patch
     `publish_outbox_batch` in `noetl/core/outbox.py` so it always
     calls `publish_event(payload)` regardless of whether
     `payload_bytes` is set.  Arrow-feather bytes stay in the
     `payload_bytes` column for any consumer that reads from the
     outbox table directly.  Live NATS consumers (gateway, future
     SSE-style listeners) get JSON.

   - **Option B:** keep arrow-feather on the existing subject for
     projector consumers and publish JSON to a NEW subject (e.g.
     `noetl.events.json.{tenant}.{org}.{exec_id}.{shard}`).
     Gateway switches subscription prefix.  More moving pieces;
     requires a coordinated noetl + gateway + ops change.

2. If Option A: also audit whether ANY existing consumer currently
   depends on the arrow-feather NATS payload.  Search across the
   noetl monorepo and gateway:

   ```
   grep -rn "_publish_event_payload\|arrow.*from.*nats\|payload_bytes" \
       repos/noetl/noetl/ repos/gateway/src/ repos/travel/src/
   ```

   If you find a projector / consumer that decodes
   arrow-feather from NATS messages, Option B becomes mandatory.

3. Open a draft PR on `noetl/noetl` with the fix + a regression
   test in `tests/core/test_outbox.py` (or wherever outbox tests
   live) that asserts the published payload over NATS is JSON
   when the outbox row carries both `payload` and `payload_bytes`.

4. Write the FINAL REPORT.

## Out of scope for Round 02

- Cluster mutations: do NOT helm upgrade, do NOT rebuild images, do
  NOT flip any env vars.  The cluster is in a healthy "login works,
  SPA hangs" state.  The post-merge deploy can happen in a later
  round once the PR is reviewed.
- Full noetl DB schema bump (the `noetl.outbox` table was applied
  in-cluster directly; other tables may need similar treatment but
  that's a separate handoff — the `noetl` DB user lacks ALTER
  permissions on pre-existing tables like `transient`, so the
  bump requires the postgres admin DSN).
- Re-enabling `NOETL_INLINE_TRIVIAL_CHILDREN=enforce`.  The worker
  is on `off` via `kubectl set env` until the SPA hang is fully
  resolved and Round B re-validation can run cleanly.

## Cluster state at thread start of Round 02

- `gke_noetl-demo-19700101_us-central1_noetl-cluster`, namespace
  `noetl`.
- Helm release `noetl`, revision **174**.
- noetl image:
  `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:inline-runner-v8-20260526204911`
  (built from `noetl@62f47dfe` = v2.102.7).
- noetl-server + noetl-worker have direct env overrides:
    `NOETL_EVENT_MIRROR_ENABLED=true`
    `NOETL_INLINE_TRIVIAL_CHILDREN=off` (worker only)
- Gateway release `noetl-gateway`, revision **128**.
- Gateway image:
  `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl-gateway:spa-fix-20260526215539`
  (built from `gateway@8d75849` = v2.11.1).
- Gateway env `NATS_UPDATES_SUBJECT_PREFIX="noetl.events."`.
- `noetl.outbox` table exists.  Receiving rows.  Most published as
  arrow-feather; the gateway can't parse them.

## Phases

### Phase A — read-only audit (no cluster mutations)

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only
   git -C repos/gateway fetch origin && git -C repos/gateway checkout main && git -C repos/gateway pull --ff-only
   ```

2. Audit consumers of the arrow-feather NATS payload:
   ```
   grep -rn "_publish_event_payload\|payload_bytes\|arrow_feather" \
       repos/noetl/noetl/ repos/gateway/src/ 2>&1 | head -40
   ```
   Decide Option A vs Option B based on whether any non-projector
   consumer reads the binary form off NATS.  Record the decision +
   evidence in the FINAL REPORT.

3. Re-read the round-01 result so the architecture context is in
   memory.

### Phase B — code change

4. Branch:
   ```
   git -C repos/noetl checkout -b kadyapam/outbox-nats-publish-json
   ```

5. Patch `repos/noetl/noetl/core/outbox.py::publish_outbox_batch`
   per the chosen option.  Comment heavily — the arrow-feather
   default has been there since the outbox feature landed
   (`ea87ba02 feat(events): add transactional outbox`) so the
   reasoning needs to be discoverable.

6. Add a regression test asserting NATS publish format.  Mock the
   `NATSEventPublisher` to capture what payload bytes get sent.
   Assert it round-trips through `json.loads` for an outbox row
   that has both `payload` (JSONB) and `payload_bytes` (arrow).

7. Run the noetl test suite (at minimum the outbox tests):
   ```
   uv run pytest tests/core/test_outbox.py -q
   ```
   Don't push if anything regresses.

### Phase C — open draft PR

8. Push the branch:
   ```
   git -C repos/noetl push -u origin kadyapam/outbox-nats-publish-json
   ```

9. Open draft PR on `noetl/noetl` with:
   - The diagnostic chain (subject mismatch fixed in #120, parser
     fixed in gateway#12, mirror flag flipped, outbox table added,
     and now the payload-encoding mismatch).
   - The fix's rationale + the consumer audit from Phase A.
   - The captured production evidence (438 outbox rows PUBLISHED,
     438 gateway parse failures, zero successful state messages).
   - A "Test plan" checklist including the post-merge rebuild +
     redeploy path.
   - Cross-link to the round-01 + round-02 result files in ai-meta.

10. Write the result file at
    `handoffs/active/2026-05-27-itinerary-planner-spa-hang/round-02-result.md`.
    Required sections:

    ```markdown
    ## Phase A — read-only audit
    - Consumer audit result + chosen option (A or B) + evidence.

    ## Phase B — code change
    - Branch name, commit SHA, file lines touched, test result.

    ## Phase C — draft PR
    - PR URL.  Confirm it is DRAFT, not merged.

    ## Issues observed
    - Grep-able fingerprints only.  No paraphrase.

    ## Manual escalation needed
    - The post-merge image rebuild + helm upgrade is gated on the
      wait phrase ``proceed with outbox JSON fix``.  Do NOT
      perform it in this round.
    ```

### Phase D — live re-test (GATED)

> ***Run only after explicit human go-ahead.  Wait phrase: `proceed with outbox JSON fix`.***

11. After the PR merges and a new noetl image rolls onto the
    cluster, retry the SPA chat flow.  Expected:
    - gateway log lines like
      `playbook_state msg received: event_type=playbook.completed exec_id=...`
    - SPA's `waitForExecutionCompletion` resolves → widget renders.

## Hard rules

- **Do NOT mutate the cluster** during Phase A–C (read + code only).
- **Do NOT merge the PR yourself.**  Open as draft.
- **Do NOT push to `main`** on any repo.
- **Do NOT log at INFO** for any new helper or test code.
- **No "canonical"** in any prose, commit message, or test
  docstring.
- **Do not store secrets** in any file under ai-meta.
- **If a precondition is missing**, stop and report — don't
  improvise.

## What success looks like

- A single focused noetl PR (preferred Option A) that makes
  outbox-published NATS payloads JSON.
- Evidence-backed decision recorded in the FINAL REPORT.
- Cluster unchanged from its current state.

## FINAL REPORT

Always emit this even on early STOP.  Frontmatter:

```yaml
---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 2
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-02-prompt.md
status: complete | partial | blocked
---
```
