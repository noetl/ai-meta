---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 1
from: claude
to: codex
created: 2026-05-27T04:31:04Z
status: open
expects_result_at: round-01-result.md
# This is a read/diagnose round.  No destructive cluster actions in
# Phases A–D.  Phase E (live re-test under enforce mode) is gated.
wait_phrase: "proceed with enforce re-test"
---

# Muno itinerary-planner SPA hangs despite playbook completing successfully

> **Predecessor:** none — fresh thread.  This bug surfaced after the
> Round B inline-execution arc was driven to production on the
> `noetl-demo-19700101` GKE cluster, but the SPA hang is reproducible
> with the inline runner **disabled**
> (`NOETL_INLINE_TRIVIAL_CHILDREN=off`), so this is a pre-existing
> orchestrator / firestore / SPA bug, not a Round B regression.  The
> closed inline-execution thread is at
> `handoffs/archive/2026-05-26-noetl-inline-trivial-children/`.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`.  Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`, `agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose),
`agents/rules/logging.md` (no INFO on hot paths).

## Symptom

`https://travel.mestumre.dev/callback` login succeeds.  The Muno chat
SPA loads.  The user types `Trip to Paris` and submits.  The SPA shows
`Hello from Muno. Tell me where you want to go, and I will build a
test-mode itinerary.` then `Muno is planning...` and **hangs
indefinitely**.  No widget update arrives.  No error visible to the
user.

## Background — what the playbook actually does

The `muno/playbooks/itinerary-planner` playbook in
`repos/travel/playbooks/itinerary-planner.yaml` IS running and IS
completing successfully on every user submission.  Captured directly
from the live cluster:

- Most recent run on `off` mode: execution `635758340626186455`,
  `status: COMPLETED`, `duration: 8.4s`, `failed: false`.
- `completed_steps` includes `normalize_input`, `load_slot_state`,
  `extract_turn`, `render_widget_chat`,
  `append_render_events_atomically`, `final_result`, and the
  upstream `persist_turn_docs_atomically`,
  `append_turn_events_atomically`.
- `final_result` step's `call.done` envelope contains a perfectly
  formed widget response:
  ```json
  {
    "status": "completed",
    "bot_message": "Pick the travel dates.",
    "thread_id": "chat-mpnjz0tl-k40jlh",
    "thread_path": "chat_threads/chat-mpnjz0tl-k40jlh",
    "render": {
      "variant": "compact",
      "widget_type": "date_range_picker",
      "schema_version": 1
    },
    "final_slot_state": {
      "region_kind": "city",
      "region_label": "Paris",
      "region_country_code": "FR",
      "region_city_code": "PAR",
      ...
    }
  }
  ```

So the orchestrator successfully produced a `date_range_picker`
widget asking the user for travel dates.  But the SPA never sees it.

## The smoking-gun observation

The playbook routes from `render_widget_chat` via an exclusive `next`
block at `repos/travel/playbooks/itinerary-planner.yaml:1413-1436`:

```yaml
next:
  spec: { mode: exclusive }
  arcs:
    - step: persist_render_docs_atomically
      when: "{{ render_widget_chat.post_docs | length > 0 }}"
      ...
    - step: append_render_events_atomically
      when: "{{ render_widget_chat.post_docs | length == 0 }}"
      ...
```

In the failing execution:

- `persist_render_docs_atomically` is **not** in `completed_steps`.
- `append_render_events_atomically` **is** in `completed_steps`.

That means the engine evaluated `render_widget_chat.post_docs | length == 0`
as true — i.e. `render_widget_chat`'s output had an empty `post_docs`
field.  No firestore documents were ever written for the widget.

The SPA listens to firestore for new widgets / chat turns.  No write,
no notification, infinite "planning…" spinner.

## What this is NOT

- **Not the Round B inline runner.**  Confirmed by switching the
  worker to `NOETL_INLINE_TRIVIAL_CHILDREN=off`; the SPA still hangs
  on the same user input with identical playbook behavior.
- **Not a sanitize / credential-alias regression.**  Login works and
  every subsequent step that needs a credential alias (pg_auth,
  firestore service account) resolved correctly.
- **Not a playbook-completion problem.**  The playbook reaches
  `final_result` cleanly in ~8s with a valid widget.

## What this might be (hypotheses to test in Phase A–D)

1. **`render_widget_chat` python code bug.**  Travel-domain Python
   that builds `post_docs` may be hitting an empty branch (e.g. an
   `if` guard returning before appending the widget doc).  Likely
   travel-side, not noetl-side.
2. **`firestore` MCP child silently failing.**  Even though
   `append_render_events_atomically` is in `completed_steps`, its
   firestore writes may be failing (auth, scope, IAM, network) and
   the worker tool envelope reports success regardless.  Earlier
   captures showed multiple `automation/agents/mcp/firestore` child
   executions stuck in `RUNNING` — those may be evidence of a
   firestore tool reliability issue on the cluster.
3. **SPA listener not subscribed to the right firestore path.**
   Gateway-side or SPA-side bug; widget docs written under one path,
   SPA listens to another.
4. **Stale or wrong firestore database / project / scope** on the
   GKE worker's service account.

## Cluster state when this thread starts

- GKE context:
  `gke_noetl-demo-19700101_us-central1_noetl-cluster`,
  namespace `noetl`.
- Helm release `noetl`, revision **174**.
- Image: `us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:inline-runner-v8-20260526204911`
  (built from `noetl@62f47dfe` = **v2.102.7**).
- Worker env `NOETL_INLINE_TRIVIAL_CHILDREN=off` via
  `kubectl set env deployment/noetl-worker` (overrides the
  ConfigMap-backed `enforce` value from `noetl/ops` PR #119).
- The Round B inline runner code is present in the image but
  inactive while the env is `off`.

## Pre-staged artifacts the executor should read

- Failing execution evidence: execution_id `635758340626186455` on
  the cluster.  Pull events + variables via
  `kubectl ... port-forward svc/noetl 18082:8082` then
  `curl -s http://localhost:18082/api/executions/635758340626186455/{status,events}`.
- Source playbook:
  `repos/travel/playbooks/itinerary-planner.yaml`
  - `render_widget_chat` step at line ~1300 (the suspect).
  - The arc routing at line 1413–1436 (the smoking gun).
  - `persist_render_docs_atomically` at line 1436.
  - `append_render_events_atomically` at line 1453.
- Firestore MCP child playbook:
  `repos/ops/automation/agents/mcp/firestore.yaml`.

## Phases

### Phase A — read-only diagnosis (no cluster mutations)

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only
   git -C repos/travel fetch origin && git -C repos/travel checkout main && git -C repos/travel pull --ff-only
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull --ff-only
   ```

2. Port-forward to GKE noetl-server:
   ```
   kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster -n noetl port-forward svc/noetl 18082:8082 &
   ```
   (Kill it at the end of the round.)

3. Pull the failing execution evidence:
   - `GET /api/executions/635758340626186455/status`
   - `GET /api/executions/635758340626186455/events` (full page,
     page_size=500)
   - `GET /api/vars/635758340626186455`
   - For every step in `completed_steps`, list the per-step events
     and the resolved variable shape.

   If that execution has been garbage-collected, trigger one more
   chat turn end-to-end via the SPA OR via a direct
   `noetl exec muno/playbooks/itinerary-planner` and use the new id.
   Do NOT execute on `enforce` mode for diagnostics — leave the
   cluster on `off`.

4. Inspect `render_widget_chat`'s actual output:
   - Where exactly is its result stored?
     (`/api/vars/<id>` → `render_widget_chat`; events under
     `node_name=render_widget_chat`; result_ref externalized to
     `/api/result/...` or `/api/temp/...`.)
   - Is `post_docs` actually empty when the run completes?  If yes,
     read the step's Python `code:` block and find the path that
     should append the widget doc but doesn't.

5. Compare to a successful trajectory: search recent executions
   (`GET /api/executions?limit=50&path=muno/playbooks/itinerary-planner`)
   and find any whose `persist_render_docs_atomically` step **is**
   in `completed_steps`.  Diff their `render_widget_chat` outputs
   against the failing one to isolate the divergent branch.

### Phase B — firestore MCP write path audit

6. There are several `automation/agents/mcp/firestore` child
   executions stuck in `RUNNING` status (captured earlier; pull a
   fresh list with
   `GET /api/executions?status=RUNNING&path=automation/agents/mcp/firestore`).
   For one or two of those:
   - Read all events; what step are they stuck on?
   - Is `firestore_dispatch` actually calling the Firestore REST API,
     and is the call succeeding?  Check worker logs for the
     execution_id with
     `kubectl ... logs deploy/noetl-worker --all-containers --tail=2000 | grep <exec_id>`.
   - If the firestore call is silently failing (e.g. 403 / wrong
     project / missing scope), capture the exact error string.

7. Independently of the orchestrator, run the firestore MCP
   playbook end-to-end with a known-good test write.  Suggested:
   register a tiny smoke playbook that calls
   `automation/agents/mcp/firestore` with
   `method: "tools/call", tool: "set_doc"` against a throwaway path
   under `chat_threads/_diag-<unique>/...` and verify the doc lands.
   Use `noetl exec` directly; no SPA involvement.

### Phase C — SPA listener side (read-only inspection)

8. The travel SPA lives in `repos/travel/` (likely under `src/` or
   `app/`).  Find where it sets up its firestore listener:
   - What firestore project + database does it bind to?
     (`noetl-demo-19700101`, default DB.)
   - What collection path does it subscribe to for new chat events?
     Typical shape: `chat_threads/<thread_id>/events` or
     `chat_threads/<thread_id>/widgets`.
   - Compare that path against what
     `append_render_events_atomically` actually writes.  If they
     diverge, **that** is the SPA-side bug.

9. Inspect gateway code at `repos/gateway/` to see if it owns the
   write-back path that the SPA expects.  The orchestrator may
   write to a path the gateway is supposed to relay from, not
   directly.  See `agents/rules/execution-model.md` — gateway is
   gatekeeper only; data writes happen inside playbook steps via
   the firestore MCP.

### Phase D — synthesis

10. Write the FINAL REPORT.  Required sections (frontmatter
    `status: complete | partial | blocked`):

    ```markdown
    ## Phase A — read-only diagnosis
    - executions inspected, render_widget_chat output shape, the
      branch in the Python code that leaves post_docs empty.

    ## Phase B — firestore MCP write path
    - whether the firestore tool actually writes, whether the
      stuck RUNNING executions point at a real defect, the smoke
      test outcome.

    ## Phase C — SPA listener
    - which firestore path the SPA listens on, which path the
      orchestrator writes, whether they match.

    ## Root cause (best inference)
    - one of: (a) render_widget_chat python bug, (b) firestore MCP
      reliability, (c) SPA listener path mismatch, (d) IAM /
      project-scope issue, (e) something else with evidence.

    ## Recommended fix
    - the smallest patch that unblocks the SPA.  If it lives in
      `repos/travel/playbooks/itinerary-planner.yaml`, name the
      step + the change.  If it lives in `repos/travel/`'s SPA
      code, name the file + the change.  If it's a firestore
      configuration issue, name the GCP IAM / scope change.

    ## Issues observed
    - bullet list with grep-able fingerprints (exact error
      strings, execution ids, step names, stack frame tops).
      Do NOT paraphrase.

    ## Manual escalation needed
    - anything that requires the human to run a destructive
      command, change IAM, or merge a PR.
    ```

### Phase E — live re-verification (GATED)

> ***Run only after explicit human go-ahead.  Wait phrase: `proceed with enforce re-test`.***

11. After the root cause is fixed and the user gives the wait
    phrase, re-flip the worker to `enforce`:
    ```
    kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
      -n noetl set env deployment/noetl-worker NOETL_INLINE_TRIVIAL_CHILDREN-
    kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster \
      -n noetl rollout status deploy/noetl-worker --timeout=2m
    ```
    The direct env override gets removed; the ConfigMap-backed
    `enforce` value from `noetl/ops#119` takes over.

12. Trigger one more SPA chat turn and confirm the widget appears.

## Hard rules

- **No code changes during Phase A–D.**  Read-only diagnostic round.
  The recommended fix is written in the report; the human or a
  later round does the patch.
- **Do not flip the cluster to `enforce`** until Phase E and the
  wait phrase.
- **Do not push to `main` on any repo** — diagnostic round.
- **Do not log at INFO** for any new helper or smoke-test code.
- **No "canonical"** in any prose, code, or commit messages.
- **Do not store secrets** in any file under ai-meta.
- **If a precondition is missing**, stop and report — don't
  improvise.

## What success looks like

- A clear, evidence-backed identification of which layer holds the
  bug (orchestrator playbook / firestore MCP tool / SPA listener /
  GCP configuration).
- The smallest viable patch named explicitly in the FINAL REPORT.
- Cluster left exactly as it was at thread start: helm rev 174,
  image `inline-runner-v8-20260526204911`, worker on
  `NOETL_INLINE_TRIVIAL_CHILDREN=off`.

## FINAL REPORT

Always emit this, even on early STOP.  Write it as the body of
`expects_result_at` with the frontmatter:

```yaml
---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```
