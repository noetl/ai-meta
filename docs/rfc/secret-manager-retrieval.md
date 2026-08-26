# RFC — retrieve prod secrets from GCP Secret Manager

**Status:** proposed, awaiting approval. **No prod secret plumbing has changed.**

Owner directive: *"We should use secret manager to retrieve secrets."*

Design only. Every figure below was read from the live cluster by reference —
no secret value was read, printed, or committed at any point, and the inventory
tooling fails closed on any credential-shaped literal
(`playbooks/267-iac-reconcile/capture.py`).

---

## 1. Inventory — what is actually secret today

### 1.1 Secret-sourced env (5 bindings, 3 distinct keys, 2 Secret objects)

| workload | container | env | secret/key |
| :-- | :-- | :-- | :-- |
| `noetl-server-rust` | `noetl-server` | `NOETL_ENCRYPTION_KEY` | `noetl-secret/NOETL_ENCRYPTION_KEY` |
| `noetl-server-rust` | `noetl-server` | `POSTGRES_PASSWORD` | `noetl-secret/NOETL_PASSWORD` |
| `noetl-server-rust` | `noetl-server` | `NOETL_INTERNAL_API_TOKEN` | `noetl-internal-api-token/token` |
| `noetl-worker-system-pool` | `noetl-worker` | `NOETL_INTERNAL_API_TOKEN` | `noetl-internal-api-token/token` |
| `noetl-worker-system-pool-shard1` | `noetl-worker` | `NOETL_INTERNAL_API_TOKEN` | `noetl-internal-api-token/token` |

Secret objects in `noetl`:

```
noetl-internal-api-token   Opaque  keys=[token]
noetl-secret               Opaque  keys=[NOETL_ENCRYPTION_KEY, NOETL_PASSWORD, POSTGRES_PASSWORD]
```

⚠ `noetl-secret/POSTGRES_PASSWORD` is **bound by nothing** — the deployment maps
env `POSTGRES_PASSWORD` from key `NOETL_PASSWORD`. Either a rename left an
orphan or a reader was removed. It should be classified before migration rather
than copied forward, because migrating an unused key teaches the new system a
falsehood.

### 1.2 The one literal — and it is **not** a secret

`NOETL_AUTH0_AUDIENCE` on `noetl-server-rust`: 32 chars, entropy 4.48, held in no
Secret. **Classified: public identifier. Does NOT belong in Secret Manager.**

Evidence, not inference:

- the identical value appears as `clientId: '…'` inside
  `ci/manifests/gateway/configmap-ui-files.yaml`, a ConfigMap whose contents are
  `index.html` / `login.html` / `app.js` / `auth.js` — **served to browsers**;
- and as `VITE_AUTH0_CLIENT_ID` in `ci/manifests/gui/deployment-prod.yaml` — a
  Vite variable, which is **compiled into the browser bundle** by definition;
- Auth0 client ids are exactly 32 alphanumeric characters.

It is an Auth0 **Client ID**, used as the JWT audience — a legitimate Auth0
pattern (an ID token's `aud` *is* the client id). Putting it in Secret Manager
would add ceremony to a value already shipped to every visitor.

⚠ The variable **name is misleading**: it is named `_AUDIENCE` and holds a client
id. Worth a rename, tracked separately from this RFC.

### 1.3 Coverage gap found while inventorying

| workload | has `NOETL_INTERNAL_API_TOKEN` | Workload Identity GSA |
| :-- | :-- | :-- |
| `noetl-server-rust` | yes | `noetl-result-tier@…` |
| `noetl-worker-system-pool` | yes | **none** |
| `noetl-worker-system-pool-shard1` | yes | **none** |
| `noetl-worker-rust` (user pool) | **no** | `noetl-worker-mcp@…` (via `noetl-worker` KSA) |
| `noetl-cmdbus-writer` | **no** | none |

Two facts to carry into design: **Workload Identity is already in use** for two
service accounts, so this is an extension rather than a greenfield; and the two
workloads that hold the token are exactly the two with **no** GSA, so they need
bindings created.

### 1.4 Classification summary

| class | items | destination |
| :-- | :-- | :-- |
| **True secret** | `NOETL_ENCRYPTION_KEY`, `NOETL_PASSWORD` (→ `POSTGRES_PASSWORD`), `noetl-internal-api-token/token` | Secret Manager |
| **Public identifier** | `NOETL_AUTH0_AUDIENCE` (an Auth0 client id), `NOETL_AUTH0_DOMAIN` (a bare hostname) | stay literal, in the repo |
| **Unclassified** | `noetl-secret/POSTGRES_PASSWORD` (bound by nothing) | decide before migrating |

Business-logic third-party credentials (Duffel, HotelBeds, Amadeus, …) are **not
in this inventory** and must not be moved here: per
`agents/rules/execution-model.md` they live in the NoETL **keychain**, referenced
by alias from playbook steps, and never in worker/gateway env. This RFC covers
**platform** credentials only.

---

## 2. Options

### (a) Secret Manager CSI driver — GKE add-on `secrets-store-csi-driver-provider-gcp`

Secrets are mounted as **files** in the pod via Workload Identity.

| | |
| :-- | :-- |
| ➕ | The only option that keeps the secret **out of etcd**, which is the actual security gain |
| ➕ | Google-managed add-on on Autopilot; no operator to run or patch |
| ➕ | Rotation by re-mount, no redeploy |
| ➖ | Pod-spec change per workload (CSI volume + mount) |
| ➖ | Delivers **files**; NoETL reads **env**, so it needs a small app-side read |

### (b) External Secrets Operator — sync Secret Manager → K8s Secret

| | |
| :-- | :-- |
| ➕ | Zero app change and zero pod-spec change — existing `secretKeyRef` keeps working |
| ➕ | Very standard, large community |
| ➖ | **The secret still lands in etcd.** Secret Manager becomes the source of truth but not the storage boundary — most of the security benefit is not realised |
| ➖ | A third-party operator to run, upgrade and monitor on a security-critical path |

### (c) App-level retrieval in Rust via Workload Identity

| | |
| :-- | :-- |
| ➕ | Strongest posture; no K8s Secret at all |
| ➕ | Matches the house preference for Rust libraries |
| ➖ | Every binary takes an SM client, retry, caching and rotation policy |
| ➖ | Adds a **hard startup dependency on Secret Manager availability** to the dispatch path. #297 is a fresh reminder of what a blocking dependency at startup costs when it is unreachable |
| ➖ | Most code, most surface, on the most sensitive path |

### Recommendation — **(a), with a ~20-line shared Rust helper**

Take the GKE-native CSI add-on and add one shared helper honouring a
`<VAR>_FILE` convention:

```
NOETL_INTERNAL_API_TOKEN_FILE=/var/secrets/internal-api-token   # preferred if set
NOETL_INTERNAL_API_TOKEN=<from secretKeyRef>                    # existing fallback
```

Resolution order: `<VAR>_FILE` if set and readable → else `<VAR>` → else the
existing error. The `_FILE` convention is well-trodden (Docker secrets, the
official Postgres images), so this is not a bespoke mechanism.

Why this rather than (b) or pure (c):

- It realises the **actual** security goal — the secret stops living in etcd,
  which (b) does not deliver.
- It gets there with one shared helper instead of an SM SDK, retry policy and
  rotation logic in every binary, so it honours the Rust preference **without**
  putting a network dependency on Secret Manager in front of startup. The pod
  either has the file or it does not; there is no call to time out.
- **Both paths coexist**, which is what makes the rollout reversible: until
  `_FILE` is set, every workload behaves exactly as it does today.

---

## 3. Workload Identity + IAM — commands **for the owner to run**

Not run by me. Per the standing boundary I do not create or modify IAM,
service accounts, or grants.

⚠ Use the right account — `shastaratech@gmail.com` for `shastaratech-noetl-prod`
(a two-session "permission gate" once turned out to be the wrong gcloud account).

```bash
PROJECT=shastaratech-noetl-prod
ACCOUNT=shastaratech@gmail.com
NS=noetl

# 0. Enable the API and the GKE add-on (one-time, cluster-wide).
gcloud services enable secretmanager.googleapis.com \
  --project=$PROJECT --account=$ACCOUNT

gcloud container clusters update noetl-prod-autopilot \
  --region=us-central1 --project=$PROJECT --account=$ACCOUNT \
  --enable-secret-manager

# 1. Create the secrets in Secret Manager.
#    ⚠ Do NOT paste values on a command line — they land in shell history and in
#    Cloud Audit Logs argument capture. Pipe from a file and shred it.
for S in noetl-internal-api-token noetl-encryption-key noetl-postgres-password; do
  gcloud secrets create $S --replication-policy=automatic \
    --project=$PROJECT --account=$ACCOUNT
done
# then, per secret:
#   gcloud secrets versions add <name> --data-file=<path> --project=$PROJECT --account=$ACCOUNT
#   shred -u <path>

# 2. Service accounts for the two workloads that have none.
gcloud iam service-accounts create noetl-system-pool \
  --display-name="NoETL system pool (Secret Manager reader)" \
  --project=$PROJECT --account=$ACCOUNT

# 3. Grant accessor PER SECRET — never project-wide secretmanager.admin.
for S in noetl-internal-api-token noetl-encryption-key noetl-postgres-password; do
  gcloud secrets add-iam-policy-binding $S \
    --member="serviceAccount:noetl-result-tier@$PROJECT.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --project=$PROJECT --account=$ACCOUNT
done
# the system pool needs ONLY the internal API token
gcloud secrets add-iam-policy-binding noetl-internal-api-token \
  --member="serviceAccount:noetl-system-pool@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --project=$PROJECT --account=$ACCOUNT

# 4. Bind KSA -> GSA (Workload Identity).
gcloud iam service-accounts add-iam-policy-binding \
  noetl-system-pool@$PROJECT.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$PROJECT.svc.id.goog[$NS/noetl-worker-system-pool]" \
  --project=$PROJECT --account=$ACCOUNT
```

`noetl-server-rust` already has `noetl-result-tier@` bound to its KSA, so it
needs step 3 only.

After the owner's grants, the KSA annotation
(`iam.gke.io/gcp-service-account`) is an ordinary manifest change and lands via
the ops repo like any other — held until approval.

---

## 4. Staged, reversible rollout

The invariant throughout: **`secretKeyRef` is not removed until Secret Manager
retrieval is proven for that workload.** Both paths are live simultaneously, so
no workload can lose its secret mid-migration.

| stage | action | proof | rollback |
| :-- | :-- | :-- | :-- |
| **0** | Owner runs §3 | secrets exist, accessor bound | delete bindings |
| **1** | Ship the `_FILE` helper in server + worker, `_FILE` unset everywhere | unit tests incl. "unset `_FILE` uses env"; kind e2e green | inert by construction — no behaviour change |
| **2** | Kind: fake-GCP or a real secret, mount CSI, set `_FILE` on **one** workload | workload authenticates; internal API calls succeed | unset `_FILE` |
| **3** | Prod, **`noetl-worker-system-pool` first** — one secret, one workload, and the pool with no user traffic | see §4.1 | unset `_FILE`; `secretKeyRef` still present |
| **4** | Prod `shard1`, then `noetl-server-rust` (3 secrets — encryption key last, it is the highest-blast-radius) | as §4.1 per secret | as above |
| **5** | Soak ≥1 week. Only then remove `secretKeyRef` and delete the K8s Secrets | a re-apply diff stays no-op | recreate the Secret from Secret Manager |

Stage 5 is the only irreversible step and gets its own explicit approval.

### 4.1 Verifying authentication **without exposing a value**

Never `echo` the file. Prove it by *effect* and by *shape*:

1. **The mount exists and is non-empty** — `stat -c %s` on the path. Size only.
2. **Provenance** — a log line/metric naming the *source*
   (`secret_source{var,source="file|env"}`), never the value. Absence of the
   metric must not read as "env": pin both label values at 0, or the missing
   series is indistinguishable from a binary that predates it.
3. **The effect** — the internal API call that needs the token succeeds. For the
   system pool that is a real orchestrate drive; a 401 is an unambiguous failure.
4. **Negative control** — unset `secretKeyRef` in a kind pod with `_FILE` set. If
   it still works, the file is genuinely the source. Without this arm a passing
   test proves only that *something* supplied the token, which is exactly the
   ambiguity that made #297 invisible for 36 hours.
5. **Digest equality, not value equality** — to confirm the SM copy matches the
   K8s Secret during dual-run, compare `sha256` of each **inside the pod** and
   compare the two digests. Never emit either value.

---

## 5. Scope, sequencing, and interaction with the item-3 reconcile

**Order matters.** The ops manifests were just reconciled so a `kubectl apply` is
a proven no-op (`noetl/ops#272`, `#273`). Every stage here changes the pod spec
(CSI volume, mount, `_FILE` env, KSA annotation), so **each stage must re-capture
and re-prove the no-op diff in the same change set**, or this RFC reintroduces
precisely the #267 drift that work removed.

`server-rust-deployment-prod.yaml` is still excluded from the reconcile pending
classification of `NOETL_AUTH0_AUDIENCE`. §1.2 resolves that: it is a **public
Auth0 client id**, so the server manifest can be folded in **as a literal**,
matching the browser-served ConfigMap. That closes item 3 and is independent of
this RFC — it needs no Secret Manager work.

**Explicitly out of scope:** business-logic third-party credentials. They belong
to the NoETL keychain by `execution-model.md`, and pulling them into platform
Secret Manager plumbing would violate that boundary.

**Not established.** Rotation cadence, whether `noetl-secret/POSTGRES_PASSWORD`
is live or orphaned, and whether the user pool and writer *should* carry an
internal API token (§1.3 shows they do not). Each is a decision, not a finding.

---

## Related

- `agents/rules/execution-model.md` — keychain vs platform credentials
- `agents/rules/safety.md` — public repo; no secrets committed
- noetl/ai-meta#267 — the IaC reconcile this must not undo
- noetl/ai-meta#297 — why a blocking startup dependency is treated as a hazard
