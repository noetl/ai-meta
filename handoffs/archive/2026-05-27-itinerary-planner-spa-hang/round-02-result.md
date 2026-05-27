---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 2
from: codex
to: claude
created: 2026-05-27T07:26:00Z
in_reply_to: round-02-prompt.md
status: complete
---

# Result — outbox publishes JSON over NATS (Option A)

Phases A–C completed.
Phase D blocked: awaiting "proceed with outbox JSON fix".

---

## Phase A — read-only audit

Grep across `repos/noetl/noetl/` and `repos/gateway/src/` for
`_publish_event_payload`, `payload_bytes`, `arrow_feather`,
`decode_projector`, and the `noetl.events.>` subject pattern.

### Consumers of the `noetl.events.*` subject

| Consumer | Location | Format |
|---|---|---|
| Gateway `playbook_state` listener | `repos/gateway/src/playbook_state.rs:29` | JSON only (`serde_json::from_slice::<Value>`) |
| Projector NATS worker | `repos/noetl/noetl/core/projector/nats_worker.py::decode_projector_notification` | JSON first, arrow-feather fallback |

No other consumers found.

### Decision

**Option A** (smallest patch — always publish JSON over NATS).

- The projector consumer already handles both formats with JSON-first
  decoding, so the wire-format flip is safe.
- The gateway is JSON-only; switching to JSON unblocks it.
- The arrow-feather binary form remains in
  `noetl.outbox.payload_bytes` for any consumer that reads the
  outbox table directly (projector fan-out by direct DB read keeps
  working untouched).
- Option B (separate JSON subject) would require coordinated
  gateway + ops + noetl changes; the consumer audit shows no need.

---

## Phase B — code change

- Branch: `kadyapam/outbox-nats-publish-json` (off `noetl@62f47dfe`).
- Commit: `a04e8950` `fix(outbox): publish JSON over NATS, not arrow-feather bytes`.

### Patches

`noetl/core/outbox.py::publish_outbox_batch`:

```diff
-            if subject and payload_bytes:
-                await event_publisher.ensure_connected()
-                await event_publisher._publish_event_payload(subject, bytes(payload_bytes))
-            else:
-                await event_publisher.publish_event(payload)
+            # Always publish JSON over NATS. The JSONB ``payload`` column is the
+            # source of truth for the event envelope; ``payload_bytes`` stays in
+            # the DB for direct-table readers (projector fan-out) only.
+            await event_publisher.publish_event(payload)
```

Plus an expanded docstring explaining the background + consumer
audit + cross-reference to the gateway parse failures.

`tests/core/test_outbox.py`:

- Existing test
  `test_publish_outbox_batch_uses_preencoded_bytes_when_subject_exists`
  renamed to
  `test_publish_outbox_batch_publishes_json_even_when_payload_bytes_present`
  and rewritten as a tripwire.  The mock's `_publish_event_payload`
  raises `AssertionError` if invoked, so any future regression to
  the arrow-feather wire format fails loudly.

### Test outcome

```
uv run pytest tests/core/test_outbox.py -q
→ 5 passed in 0.52s
```

---

## Phase C — draft PR

- Branch pushed: `kadyapam/outbox-nats-publish-json` → `origin`.
- Draft PR: **https://github.com/noetl/noetl/pull/620** (status `OPEN`, `isDraft: true`, not merged).

PR body cites the live production evidence (438 outbox PUBLISHED + 438 gateway parse failures + 0 successful state messages), names the predecessor chain (noetl#617/#618/#619, gateway#12, ops#120), and flags noetl/ops#121 as a hold-until-DB-schema-bump.

---

## Phase D — live re-verification

Phase D blocked: awaiting "proceed with outbox JSON fix".

Cluster left exactly as found:
- noetl helm rev 174, image `inline-runner-v8-20260526204911` (v2.102.7).
- gateway helm rev 128, image `spa-fix-20260526215539` (v2.11.1).
- `NOETL_EVENT_MIRROR_ENABLED=true` via `kubectl set env` on both noetl-server and noetl-worker.
- `NOETL_INLINE_TRIVIAL_CHILDREN=off` via `kubectl set env` on worker.
- `noetl.outbox` table exists.

After PR #620 merges, the post-merge deploy is:

```
# Wait for PyPI v2.102.8 publish
# Rebuild noetl image off main
gcloud builds submit --config=...                         # builds inline-runner-v9-<ts>
PATH=...:$PATH helm --kube-context gke_... -n noetl upgrade noetl \
  repos/ops/automation/helm/noetl --reuse-values \
  --set image.tag=inline-runner-v9-<ts> --wait
```

Then retry the SPA chat at `travel.mestumre.dev` and confirm:
- gateway logs show `playbook/state` deliveries instead of parse failures
- SPA receives the `date_range_picker` widget instead of hanging on
  "Muno is planning…"

---

## Issues observed

- Bash access was restricted in the round-02 codex environment; the
  initial run of this round could not commit/push or open the PR.
  Phases B–C completed after the dispatcher (claude) committed and
  pushed the code changes that were already drafted in the worktree.
- 4 outbox rows already in `FAILED` state on the cluster with
  `nats: maximum payload exceeded`.  These are large-payload events
  whose JSON also exceeds the NATS default max payload (1 MiB).
  Not in scope for this round — separate operational followup
  (raise the NATS max payload limit, or chunk + reference large
  events).  Captured for future tracking.

---

## Manual escalation needed

- **Merge PR #620.**
- After PyPI v2.102.8 publishes, rebuild + redeploy the noetl
  image on the GKE demo cluster.
- Say the wait phrase `proceed with outbox JSON fix` to unlock
  Phase D live re-verification (or run it directly — the
  command sequence is in Phase D above).
- The 4 oversized outbox events that hit `nats: maximum payload
  exceeded` may need to be cleared manually
  (`UPDATE noetl.outbox SET status='PUBLISHED' WHERE status='FAILED'`)
  so the publisher doesn't keep retrying them, OR investigated to
  see what payload is exceeding NATS's max.
