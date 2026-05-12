# Google Maps Platform setup for travel agent — Pattern C (hybrid auth)

**Audience**: Kadyapam, before firing the Google Places enrichment bridge round
(`20260512-030000-google-places-enrichment-mcp`).

**Status**: One-time setup. After this completes, the bridge round can fire
end-to-end. Estimated time: 15-25 minutes.

**Last updated**: 2026-05-12

---

## What this sets up

Pattern C = hybrid auth for the travel agent's Google Places enrichment layer:

- **Backend API calls** (`places.searchText`, `places.details`, `places.nearbySearch`,
  Routes API) → authenticated via the **worker Service Account's Workload Identity**.
  No secret to manage for these calls. Same pattern Vertex AI already uses.

- **Widget-embedded URLs** (Maps Static API images, Place Photos) → authenticated
  via a **restricted API key** embedded in the URL the browser fetches. Necessary
  because the browser can't carry a service-account token. The API key is scoped
  to only image-serving endpoints, restricted by HTTP referrer, and quota-capped.

Why hybrid: matches existing project security posture (SA + Workload Identity)
for backend calls; widget API key is unavoidable for image URLs but has minimal
blast radius if leaked from page HTML.

---

## Prerequisites

- `gcloud` CLI authenticated to `noetl-demo-19700101` project.
- Cloud Console access (some steps are easier in the UI than CLI).
- Knowledge of which service account the noetl-worker pods use. Per prior memory
  entries this is `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`.
- **Target cluster is GKE** with Workload Identity wired on `noetl-worker-mcp`.
  See "Cluster context" below — this playbook does not apply to local kind.

---

## Cluster context — GKE only

The backend SA OAuth path described here relies on the GCE/GKE metadata server
to mint tokens for the worker SA via Workload Identity. That mechanism does not
exist on local kind clusters (`kind-noetl`), so the verification probe in Step 3
cannot succeed there.

Cluster-specific differences observed in this project as of 2026-05-12:

| Aspect | GKE (Pattern C target) | Local `kind-noetl` |
|---|---|---|
| Worker SA name | `noetl-worker-mcp` (with WI annotation) | `noetl-worker` (no annotations) |
| GCP auth path | Workload Identity → metadata server | Requires real SA JSON key file |
| `GOOGLE_APPLICATION_CREDENTIALS` env | Should be unset (lets ADC use WI) | Currently set to `/etc/gcs/gcs-key.json` |
| `/etc/gcs/gcs-key.json` content | Real key or absent | Placeholder `{}` from dev bootstrap |

On local kind the placeholder `gcs-key.json` is a **load-bearing blocker**:
`google.auth.default()` reads `GOOGLE_APPLICATION_CREDENTIALS` first and fails
with `Type is None` before any other auth path runs. See the troubleshooting
section below ("Q: Worker pod fails with `The file /etc/gcs/gcs-key.json does
not have a valid type`").

If you need Places enrichment on kind for local validation, the Pattern C SA
OAuth path is not the right vehicle — use a per-tool SA key mounted at a
separate path, or run the validation on GKE.

---

## Step 1 — Enable Google Maps Platform APIs

Run once:

```bash
gcloud services enable \
  places-backend.googleapis.com \
  maps-backend.googleapis.com \
  static-maps-backend.googleapis.com \
  routes.googleapis.com \
  --project=noetl-demo-19700101
```

Verify:

```bash
gcloud services list --enabled --project=noetl-demo-19700101 \
  | grep -E 'places|maps|routes|static'
```

You should see all four services listed.

---

## Step 2 — Grant the worker Service Account permissions for backend calls

The worker SA needs two roles to call Maps Platform APIs via OAuth:

1. **`roles/serviceusage.serviceUsageConsumer`** — required to call any enabled
   Google API in the project.
2. **API-specific consumer role** — for Places + Routes, the SA needs to be able
   to "consume" the service. The simplest grant is project-level:

```bash
# Required: serviceUsageConsumer for any GCP API call
gcloud projects add-iam-policy-binding noetl-demo-19700101 \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/serviceusage.serviceUsageConsumer
```

Verify the binding landed:

```bash
gcloud projects get-iam-policy noetl-demo-19700101 \
  --flatten='bindings[].members' \
  --filter='bindings.members:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com' \
  --format='value(bindings.role)'
```

You should see at least:
- `roles/serviceusage.serviceUsageConsumer` (this step)
- `roles/aiplatform.user` (Vertex AI, from earlier work)
- `roles/secretmanager.secretAccessor` (multiple secrets, from earlier work)
- `roles/storage.objectAdmin` (GCS spillover bucket)

If `roles/serviceusage.serviceUsageConsumer` is missing after the bind command,
the command silently failed — re-run with `--verbosity=debug`.

---

## Step 3 — Verify backend OAuth works (sanity check before the bridge round)

This is the most important check. If it fails, the bridge round will AMBER and
nothing will work end-to-end. Better to catch it now.

Test from inside a worker pod (so we're using the actual Workload Identity binding,
not your local gcloud credentials):

```bash
# Get a worker pod name
WORKER_POD=$(kubectl -n noetl get pods -l app=noetl-worker -o jsonpath='{.items[0].metadata.name}')

# Exec into it and call Places API with the SA's identity
kubectl -n noetl exec $WORKER_POD -- python -c "
import google.auth
import google.auth.transport.requests
import urllib.request, urllib.error, json

credentials, project = google.auth.default(
  scopes=['https://www.googleapis.com/auth/cloud-platform']
)
request = google.auth.transport.requests.Request()
credentials.refresh(request)

req = urllib.request.Request(
  'https://places.googleapis.com/v1/places:searchText',
  data=json.dumps({'textQuery': 'restaurants in Paris'}).encode('utf-8'),
  headers={
    'Authorization': f'Bearer {credentials.token}',
    'X-Goog-User-Project': 'noetl-demo-19700101',
    'X-Goog-FieldMask': 'places.displayName,places.formattedAddress',
    'Content-Type': 'application/json',
  },
  method='POST',
)
try:
  resp = urllib.request.urlopen(req, timeout=15)
  print('STATUS:', resp.status)
  print('BODY:', resp.read().decode('utf-8')[:500])
except urllib.error.HTTPError as e:
  print('HTTP ERROR:', e.code)
  print('BODY:', e.read().decode('utf-8')[:500])
"
```

Expected output: `STATUS: 200` and a JSON body with `places` array containing
Paris restaurants.

Common failure modes:

| Error | Meaning | Fix |
|---|---|---|
| `403 PERMISSION_DENIED` with `Cloud Resource Manager API has not been used` | Service-usage consumer role didn't land yet, or wrong service | Re-run Step 2 |
| `403 PERMISSION_DENIED` mentioning Places API | Places API not enabled OR SA can't call it | Re-run Step 1; verify enabled |
| `400 INVALID_ARGUMENT` mentioning field mask | The probe command is wrong, not your auth | Copy the command exactly |
| `401 UNAUTHENTICATED` | Workload Identity not wired on this pod | Different problem — check the pod's SA annotation |

Don't proceed to Step 4 until this returns `STATUS: 200`.

---

## Step 4 — Create the widget-restricted API key

This key embeds in browser-fetched URLs (Maps Static images and Place Photos).
It's restricted aggressively because it's effectively public once the widget renders.

**Do this in Cloud Console**, not gcloud — the UI for API key restrictions is much
clearer:

1. Open https://console.cloud.google.com/apis/credentials?project=noetl-demo-19700101
2. Click **+ Create Credentials** → **API key**
3. The new key appears in a modal. Click **Edit API key** (or the pencil icon on
   the key row).
4. Set **Name**: `travel-agent-widget-key` (or similar).
5. Under **Application restrictions**:
   - Select **HTTP referrers (web sites)**
   - Add these referrer patterns one at a time:
     - `https://mestumre.dev/*`
     - `https://gateway.mestumre.dev/*`
     - `https://*.pages.dev/*` ← only if you also want preview Pages deploys
6. Under **API restrictions**:
   - Select **Restrict key**
   - From the dropdown, select ONLY:
     - **Maps Static API**
     - **Places API (New)** — needed for Place Photos endpoint
   - Do NOT include Places search/details/nearbySearch (those go via SA OAuth).
7. (Recommended) Under **Quotas & limits**:
   - The default per-day quota is unlimited. Set explicit per-day caps:
     - Maps Static API: 5000 requests/day
     - Places API (New) Photos: 5000 requests/day
   - These are hard ceilings against runaway burn; the bridge round also enforces
     per-execution caps.
8. **Save**.
9. Copy the key value (starts with `AIza...`). You'll need it for Step 5.

**Why restricted to widget endpoints only**: the SA OAuth path handles search/
details/nearbySearch calls server-side. The API key only handles image URL
construction. If the key leaks, the worst an attacker can do is fetch images
until your daily quota runs out.

---

## Step 5 — Store the widget API key in Secret Manager

```bash
echo -n '<paste-the-AIza-key-from-Step-4>' | gcloud secrets create google-maps-widget-key \
  --replication-policy=automatic --project=noetl-demo-19700101 --data-file=-

# Grant worker SA access
gcloud secrets add-iam-policy-binding google-maps-widget-key \
  --project=noetl-demo-19700101 \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

Verify the secret is readable from the worker SA's perspective:

```bash
gcloud secrets versions access 1 --secret=google-maps-widget-key \
  --project=noetl-demo-19700101 \
  | head -c 8 && echo ...
```

Expected: shows the first 8 characters (something like `AIzaSyBx`) followed by
`...`. If it shows the entire key, that's fine — the `head -c 8` truncated it
locally, but the secret value is intact in GCP.

**Never echo the full key.** This document is committed to a public repo
(`ai-meta`). The recipe is here; the actual key value stays in Secret Manager.

---

## Step 6 — Verify everything is in place before pushing the bridge task

Quick checklist:

```bash
# APIs enabled (4 expected)
gcloud services list --enabled --project=noetl-demo-19700101 \
  | grep -cE 'places-backend|maps-backend|static-maps-backend|routes' 
# Expected: 4

# SA roles include serviceUsageConsumer
gcloud projects get-iam-policy noetl-demo-19700101 \
  --flatten='bindings[].members' \
  --filter='bindings.members:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com AND bindings.role:roles/serviceusage.serviceUsageConsumer' \
  --format='value(bindings.role)'
# Expected: roles/serviceusage.serviceUsageConsumer

# Widget API key secret exists + SA can read it
gcloud secrets describe google-maps-widget-key --project=noetl-demo-19700101 \
  --format='value(name)'
# Expected: projects/<num>/secrets/google-maps-widget-key

gcloud secrets get-iam-policy google-maps-widget-key --project=noetl-demo-19700101 \
  --flatten='bindings[].members' \
  --filter='bindings.members:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com' \
  --format='value(bindings.role)'
# Expected: roles/secretmanager.secretAccessor
```

All four checks pass → ready for the bridge round.

---

## Step 7 — Push the bridge task

```bash
cd /Volumes/X10/projects/noetl/ai-meta
git add bridge/inbox/delegated/20260512-030000-google-places-enrichment-mcp.task.json \
        scripts/google_places_enrichment_mcp_msg.txt \
        memory/inbox/2026/05/20260512-030000-handed-google-places-enrichment-to-codex.md \
        playbooks/google-maps-platform-setup-pattern-c.md

git commit -m "chore(bridge): hand Google Places enrichment (Pattern C hybrid auth) to Codex

Backend Places/Routes calls go via Workload Identity on the worker SA.
Widget-embedded image URLs use a restricted API key (HTTP referrer +
API restriction + per-day quota). Setup playbook lives at
playbooks/google-maps-platform-setup-pattern-c.md."

git push origin main
```

---

## Step 8 — Paste the trigger prompt into Codex

After the push lands:

```
Add Google Places + Maps as an opt-in enrichment layer for the travel agent.
Pattern C: backend OAuth via worker SA Workload Identity for Places/Routes
calls; restricted API key in Secret Manager for widget-embedded image URLs.
Default OFF.

Bridge task: bridge/inbox/delegated/20260512-030000-google-places-enrichment-mcp.task.json
Prompt details: scripts/google_places_enrichment_mcp_msg.txt
Setup reference: playbooks/google-maps-platform-setup-pattern-c.md
Result file: bridge/outbox/20260512-030000-google-places-enrichment-mcp.result.json

Pre-handoff: Pattern C setup complete (Maps APIs enabled, SA has
serviceUsageConsumer, widget API key in google-maps-widget-key secret).

Run all 9 phases per the bridge task. Architectural rules:
  - Supplementary, NOT replacement for Amadeus
  - Default OFF (opt-in via workload field)
  - Per-execution cap: max 10 enrichments
  - Enrichment failure is non-blocking
  - Hybrid auth: SA OAuth for search/details/nearby; widget key for
    Maps Static + Place Photos URLs only
  - No release cut. No git push from ai-meta.

If any pre-handoff check fails: AMBER + STOP, point Kadyapam at
playbooks/google-maps-platform-setup-pattern-c.md.
```

---

## Troubleshooting

**Q: The Places API probe in Step 3 returns 403 even after granting `serviceUsageConsumer`.**

Wait 60 seconds. IAM changes propagate quickly but not instantly. If still 403,
double-check the SA email matches exactly:
`noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`. Typos in the SA
address silently bind to nothing.

**Q: The widget API key works in browser but server-side curl returns 403.**

That's correct — the widget key has HTTP referrer restrictions, so server-side
calls (which don't send a `Referer` header that matches the allowed patterns)
get rejected. Server-side calls should use the SA OAuth path, not the widget key.

**Q: Bridge round AMBERs on phase 1 with "API key probe failed."**

Phase 1 does a direct backend probe via the SA OAuth flow. If it fails, run the
Step 3 probe from this doc manually and compare. The fix is almost always one of:
- Forgot to enable an API in Step 1
- Forgot the `serviceUsageConsumer` role in Step 2
- Using the widget key instead of SA OAuth

**Q: Worker pod fails with `The file /etc/gcs/gcs-key.json does not have a valid type. Type is None`.**

Observed on `kind-noetl` 2026-05-12 while attempting the Step 3 SA OAuth probe
from a worker pod. The pod has `GOOGLE_APPLICATION_CREDENTIALS=/etc/gcs/gcs-key.json`
hardcoded in the deployment, and the mounted file is a `{}` placeholder created
by the dev bootstrap (`repos/ops/automation/development/noetl.yaml`,
`kubectl create secret generic gcs-credentials ... --from-literal=gcs-key.json='{}'`).
`google.auth.default()` reads the env-pointed file before any fallback chain,
so the placeholder blocks every auth path including Workload Identity.

Diagnose (read-only):

```bash
WORKER_POD=$(kubectl -n noetl get pods -l app=noetl-worker -o jsonpath='{.items[0].metadata.name}')

# Confirm the env var points at the placeholder
kubectl -n noetl get pod $WORKER_POD -o jsonpath='{range .spec.containers[?(@.name=="worker")].env[*]}{.name}={.value}{"\n"}{end}' | grep GOOGLE

# Confirm the pod's SA + annotation state (kind: expect no annotations)
kubectl -n noetl get pod $WORKER_POD -o jsonpath='{.spec.serviceAccountName}'; echo
kubectl -n noetl get sa $(kubectl -n noetl get pod $WORKER_POD -o jsonpath='{.spec.serviceAccountName}') -o jsonpath='{.metadata.annotations}'; echo
```

Fix paths:

- **On GKE (Pattern C target)**: remove the `GOOGLE_APPLICATION_CREDENTIALS`
  env entry and the `/etc/gcs` mount from the worker deployment so ADC falls
  through to the metadata server. The worker SA must already have the
  `iam.gke.io/gcp-service-account` annotation binding to
  `noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com`. Source manifest:
  `repos/ops/ci/manifests/noetl/worker-deployment.yaml` (and the noetl-submodule
  mirror at `repos/noetl/ci/manifests/noetl/worker-deployment.yaml`). Submodule
  edit — file via the noetl bridge, not from ai-meta.
- **On local kind**: Pattern C is not applicable (no metadata server). Either
  replace the `gcs-credentials` secret with a real SA JSON key for local-only
  testing, or mount a per-tool SA key at a separate path and have the Places
  MCP load it explicitly instead of relying on ADC.

**Q: I want to verify the widget API key independently.**

```bash
WIDGET_KEY=$(gcloud secrets versions access 1 --secret=google-maps-widget-key \
  --project=noetl-demo-19700101)

# Test a Maps Static URL (no referrer header → blocked unless you remove referrer
# restriction temporarily). Better test: open the URL in a browser tab from a
# page served at mestumre.dev. For headless verification:
curl -H "Referer: https://mestumre.dev/test" \
  "https://maps.googleapis.com/maps/api/staticmap?center=Paris&zoom=12&size=200x200&key=${WIDGET_KEY}" \
  -o /tmp/test-map.png

file /tmp/test-map.png
# Expected: /tmp/test-map.png: PNG image data
```

If the response is `403 Forbidden` or HTML instead of PNG: referrer restrictions
don't match. Adjust in Cloud Console (Step 4 point 5).

---

## Cost ceiling — what you're protected against

Three nested defenses against runaway burn:

1. **Bridge round per-execution cap**: max 10 enrichment items per travel execution.
   Hardcoded in the playbook.
2. **GCP API key per-day quota**: 5000 requests/day per Maps Static and Places API
   (Step 4 point 7). After 5000, requests return 403 until the next day.
3. **Google Maps Platform free credit**: $200/month. At Places Details Enterprise
   pricing (~$17/1000), that's ~11,700 calls/month before any charges. At Maps
   Static (~$2/1000), ~100,000 calls/month free.

At expected demo + low-traffic production usage (~30 executions/day × 10 items =
~9000 enrichment calls/month), you use ~5-10% of the free credit. Costs you
nothing.

For any real load (hundreds of executions/day), revisit the budget math before
relying on the free tier.
