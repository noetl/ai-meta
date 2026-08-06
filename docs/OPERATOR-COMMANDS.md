# Operator command sheet

Actions only a human can take. Every name below was verified read-only against
production on **2026-08-06** — service accounts from `gcloud iam
service-accounts list`, the build SA from the repo variable `GCP_CLOUDBUILD_SA`,
the worker identity from the live `iam.gke.io/gcp-service-account` annotation,
and API names from the endpoints the playbooks actually call.

Run them in any order; they are independent. After each, the listed follow-up is
something the agent can do without further input.

**Project:** `shastaratech-noetl-prod`
**Account to use:** `shastaratech@gmail.com` — ⚠ `kadyapam@gmail.com` owns the
old project and cannot see this one; using the wrong account has cost two
sessions before.

```bash
gcloud config set account shastaratech@gmail.com
```

---

## ⚠ First, a correction worth reading

There are **two different** `serviceUsageConsumer` grants, on **two different
service accounts**, for **two unrelated problems**. They are easy to conflate
because the role name is identical.

| | principal | fixes |
| :-- | :-- | :-- |
| §1 | `gh-actions-cloudbuild@…` | the CI release job (#211) |
| §2 | `noetl-worker-mcp@…` | the Places API 403 at runtime (#234) |

Granting only the first will **not** fix google-places, and vice versa.

---

## 1. IAM grant — unblock the CI release job (#211)

The build service account is `gh-actions-cloudbuild@shastaratech-noetl-prod.iam.gserviceaccount.com`
(verified: it exists, and matches the `GCP_CLOUDBUILD_SA` repo variable on
`noetl/server`).

```bash
gcloud projects add-iam-policy-binding shastaratech-noetl-prod \
  --member="serviceAccount:gh-actions-cloudbuild@shastaratech-noetl-prod.iam.gserviceaccount.com" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --account=shastaratech@gmail.com
```

**Verify:**

```bash
gcloud projects get-iam-policy shastaratech-noetl-prod \
  --account=shastaratech@gmail.com \
  --flatten="bindings[].members" \
  --filter="bindings.members:gh-actions-cloudbuild@shastaratech-noetl-prod.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

Expect `roles/serviceusage.serviceUsageConsumer` in the output.

**Then re-run the release and read the next error, do not assume it is fixed:**

```bash
gh workflow run release-server.yml --repo noetl/server
gh run watch --repo noetl/server
```

⚠ **If `publish-ar` still fails, read the new message rather than re-granting.**
The recorded history on #211 is that GCP reported this denial *in terms of the
staging bucket*, which made a storage grant look like the obvious fix — and it
was the wrong one. The bucket role is already applied. If the next error names a
bucket again, capture it verbatim and hand it back rather than acting on it.

**Unblocks:** `publish-ar` on every release, for both `noetl/server` and
`noetl/worker`.

**What the agent does next, unprompted:** re-runs the release, reads the tag
back, and — if `publish-ar` now succeeds — retires the `crane copy` GHCR→AR
workaround from the deploy runbook, since it exists only because this job fails.

---

## 2. Enable the APIs that exist only in the old project (#234)

Production currently has **only** `secretmanager` and `serviceusage` enabled of
the relevant set. The old project `noetl-demo-19700101` has Places, Maps,
Firestore and Vertex. That asymmetry — not the project *name* in the playbooks —
is why those references cannot simply be repointed.

### 2a. Places + Maps Static — unblocks `mcp/google-places` and the planner's enrichment

Confirmed from the endpoints the playbooks actually call:

| endpoint in the playbook | API to enable |
| :-- | :-- |
| `https://places.googleapis.com/v1/places:searchText` (and `:searchNearby`, `/v1/places/…`) | `places.googleapis.com` |
| `https://maps.googleapis.com/maps/api/staticmap` | `static-maps-backend.googleapis.com` |

```bash
gcloud services enable places.googleapis.com \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com

gcloud services enable static-maps-backend.googleapis.com \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
```

**Also required for these two — the runtime grant.** The Places 403 is *not* the
build SA. Production worker pods run as KSA `noetl-worker`, annotated to GSA
`noetl-worker-mcp@shastaratech-noetl-prod.iam.gserviceaccount.com` (verified from
the live ServiceAccount annotation). The backend call sends
`X-Goog-User-Project`, which requires:

```bash
gcloud projects add-iam-policy-binding shastaratech-noetl-prod \
  --member="serviceAccount:noetl-worker-mcp@shastaratech-noetl-prod.iam.gserviceaccount.com" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --account=shastaratech@gmail.com
```

**Verify all three:**

```bash
gcloud services list --enabled --project=shastaratech-noetl-prod \
  --account=shastaratech@gmail.com \
  --filter="config.name:(places.googleapis.com OR static-maps-backend.googleapis.com)" \
  --format="value(config.name)"

gcloud projects get-iam-policy shastaratech-noetl-prod \
  --account=shastaratech@gmail.com --flatten="bindings[].members" \
  --filter="bindings.members:noetl-worker-mcp@shastaratech-noetl-prod.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

**What the agent does next, unprompted:** repoints `automation/agents/mcp/google-places`
to prod (it currently sits at v12, byte-identical to v10, after a deliberate
rollback), then proves it with a real `search_text` call — success is *places
returned > 0*, **not** `status: COMPLETED`, because a failing provider still
reports COMPLETED (#246). Rolls back instantly by re-registering the old bytes
if it does not return results.

### 2b. Vertex AI — for `automation/agents/travel/runtime`'s `vertex_project`

`automation/agents/mcp/vertex-ai` calls
`https://{region}-aiplatform.googleapis.com/v1/projects/…:generateContent`, so
the API is:

```bash
gcloud services enable aiplatform.googleapis.com \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
```

That provider's own error text also names `roles/aiplatform.user` as a
prerequisite alongside Workload Identity. **Confirm whether the worker GSA needs
that role** before granting it — the agent has not been able to verify it
read-only, and it is a separate grant from the one in §2a:

```bash
# inspect only — decide before granting
gcloud projects get-iam-policy shastaratech-noetl-prod \
  --account=shastaratech@gmail.com --flatten="bindings[].members" \
  --filter="bindings.members:noetl-worker-mcp@shastaratech-noetl-prod.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

**What the agent does next:** splits `travel/runtime`'s two references —
`gcp_project` can move with the secret reads, `vertex_project` only after this
API is on — and validates each separately.

### 2c. Firestore — **read §3 first, this one is not a repoint**

```bash
gcloud services enable firestore.googleapis.com \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
```

Enabling the API is safe and reversible. **Do not repoint the provider after
running it** — see below.

---

## 3. ⚠ Firestore is a DATA MIGRATION, not an API-enable plus a repoint

`automation/agents/mcp/firestore`'s `gcp_project` selects **which Firestore
database holds the data**, not merely where a credential is read. Enabling the
API in production creates the *ability* to talk to a Firestore there; it moves
**nothing**.

If the provider is repointed without migrating:

- Existing Muno thread documents stay in `noetl-demo-19700101` and become
  invisible to the application.
- New writes land in a different, empty database.
- **Re-pinning the old catalog version does not undo it.** Catalog rollback
  restores which project the playbook *names*; it cannot retrieve documents
  written to the wrong database in the meantime. This is the one step in #234
  that catalog versioning cannot reverse.

Deciding it entails answering, in order:

1. **Is there data worth keeping?** Count the documents in the old project's
   Firestore first. If the collections are empty or disposable, this collapses
   into a simple repoint and the rest does not apply.
2. **If yes — migrate or dual-read?** A one-shot export/import needs a write
   freeze to avoid split-brain; a dual-read period needs application support
   that does not exist today.
3. **Which collections?** The provider exposes `get_doc`, `set_doc`,
   `query_collection`, `replay_events` and batch variants, so the blast radius
   is whatever the SPA and planner persist through it.
4. **What is the rollback?** Once writes land in two databases, rollback means
   reconciling them. Decide the abort condition *before* starting.

**The agent will not attempt this**, and has left the provider untouched. It is
the only #234 item deliberately excluded on irreversibility grounds rather than
on missing permissions.

---

## 4. Two actions with no command

### 4a. One real application login — unblocks JWT enforcement (#169)

Auth0 JWT signature verification is shipped but running in **shadow** (it
allows everything and only logs). It cannot be switched to enforce because the
`aud` (audience) claim value is unknown, and the only reliable way to learn it
is to observe one genuine token.

**Do:** log into the application once, normally, through the real UI.

That is the entire action — no console, no command. The agent reads the `aud`
from the resulting shadow-verification log line.

**Why it matters:** until enforce is on, a forged or expired token is accepted
in production. The verification code exists and is running; it just is not
allowed to reject anything yet.

**What the agent does next:** reads `aud` from the shadow log, sets it in the
gateway config, flips verification to enforce, and validates with a real login
plus a deliberately invalid token — rolling back the flag instantly if a valid
login is rejected.

### 4b. Verify the alert email channel in the GCP console (#238)

Prod alerting exists as of 2026-08-05 — 5 policies, all enabled, all evaluating
correctly against live data. The email channel
(`akuksin@gmail.com`) reports **`verificationStatus` unset**, and GCP can decline
to deliver to an unverified address.

If that is the case, every policy fires correctly and **notifies nobody** —
which is the exact failure #238 was opened about, one hop further along.

**Do:**

1. Open **Cloud Monitoring → Alerting → Notification channels**
   → <https://console.cloud.google.com/monitoring/alerting/notifications?project=shastaratech-noetl-prod>
2. Find the `email` channel for `akuksin@gmail.com`.
3. If it shows unverified, send the verification and confirm from the inbox.

**Quick alternative that settles it in one look:** a synthetic alert was fired
deliberately on 2026-08-06 (a throwaway execution tripping a provider-error
metric; the temporary policy was deleted afterwards). **If an alert email from
that test is in the inbox, the channel is fine and nothing needs doing.**

⚠ This cannot be verified from the API side. `GET /v3/projects/*/incidents`
returns 404, the `monitoring.googleapis.com/alerting/*` metric family has **zero
descriptors** in this project, and `gcloud alpha monitoring` is not installed —
so "no incidents found" means *cannot observe*, not *nothing fired*.

**What the agent does next:** re-fires a controlled synthetic alert on request so
delivery can be confirmed end-to-end, then deletes the temporary policy again.

---

## Quick reference

| # | Action | Type | Unblocks |
| :-- | :-- | :-- | :-- |
| 1 | grant `serviceUsageConsumer` to **gh-actions-cloudbuild** | command | CI release (`publish-ar`), #211 |
| 2a | enable `places.googleapis.com` + `static-maps-backend.googleapis.com`, grant `serviceUsageConsumer` to **noetl-worker-mcp** | command | google-places + planner enrichment, #234 |
| 2b | enable `aiplatform.googleapis.com` | command | travel/runtime Vertex, #234 |
| 2c | enable `firestore.googleapis.com` | command | prerequisite only — **read §3** |
| 3 | Firestore data migration | **decision** | the last #234 item; not reversible by catalog rollback |
| 4a | one real app login | manual | JWT enforce, #169 |
| 4b | verify the alert email channel | console | alert delivery, #238 |

Nothing here is done by the agent: §1, §2 and §4b are IAM/console actions
outside its remit, §3 is a design decision, and §4a needs a human at a login
screen.
