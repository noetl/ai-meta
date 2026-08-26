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

### 1.4 Auth0 — corrected after the owner's clarification

> *"Auth0 used for playbooks like travel service when they need it for app."*

Auth0 is **two flows**, and they have opposite secret postures.

**Flow A — browser login (travel, GUI).** `repos/travel/src/auth/authConfig.ts`
carries `DEFAULT_AUTH0_CLIENT_ID` and reads `VITE_AUTH0_CLIENT_ID` — a Vite
variable, so it is compiled into the shipped bundle. Same value in the gateway's
browser-served `auth.js` ConfigMap and the GUI deployment.

**Flow B — machine-to-machine token minting.**
`api_integration/auth0/get_auth0_token` (registered in prod, along with 8 more
Auth0 playbooks) POSTs `https://<domain>/oauth/token`. Its own header says
*"Retrieves Auth0 client secret from NoETL credential table"*, and it takes the
secret by **keychain alias**:

```yaml
keychain:
  - name: auth0_credentials
    kind: credential
    credential: "{{ auth0_credential }}"    # default: auth0_client
...
        client_secret: "{{ keychain.auth0_credentials.client_secret }}"
```

The client id appears there too, as a **committed plaintext default** — a fourth
independent confirmation that it is public.

### 1.4.1 The three buckets

| bucket | material | where it lives | destination |
| :-- | :-- | :-- | :-- |
| **(a) public identifier** | `NOETL_AUTH0_AUDIENCE` (holds the **client id**), `NOETL_AUTH0_DOMAIN`, `VITE_AUTH0_*` | workload env literal; browser bundle; playbook defaults | **stay literal.** Already public in four places |
| **(b) platform-auth secret** | `NOETL_ENCRYPTION_KEY`, `POSTGRES_PASSWORD`, `NOETL_INTERNAL_API_TOKEN` | workload env via `secretKeyRef` | **Secret Manager** — see §2 |
| **(c) external-subsystem secret** | **`auth0_client`** (type `auth0`), plus genuine third-party creds (`duffel_token`, `gcs_*`, `sf_test`, `ib_*`) | **NoETL keychain**, alias-referenced at execution time | keychain — whose backend is **already Secret Manager**, see §1.5 |

**Where the line falls, and why the Auth0 client secret is (c) not (b):** the test
is not "whose authentication is it" but **who consumes the credential**. The
Auth0 client secret is consumed by a *playbook step* calling an *external*
endpoint (`https://<tenant>.auth0.com/oauth/token`).
`agents/rules/data-access-boundary.md` names this exact case as the textbook
external-subsystem exception. That the resulting token then authenticates a
caller to the app does not move the *secret* — Auth0 is still the counterparty.

⚠ Confirmed present in prod: `auth0_client`, type `auth0`. It was **not** missed
by §1.1 — §1.1 scanned workload env, and this correctly is not there.

⚠ `NOETL_AUTH0_AUDIENCE` is misnamed: it holds a client id. In
`get_auth0_token` the *audience* is a URL (`https://<domain>/me/`), a different
value. Worth a rename; tracked separately.

### 1.5 ⚠⚠ The wallet already exists — and is already resolving from Secret Manager on prod

The most important finding of this pass, and it reshapes the whole RFC.
`repos/server/src/secrets/` is a full **Secrets Wallet** (noetl/ai-meta#61):

```
gcp.rs  gcp_iam.rs  aws.rs  aws_sts.rs  azure.rs  azure_oauth.rs  vault.rs  k8s.rs
mod.rs (trait SecretProvider)  registry.rs  resolver.rs  broker.rs  residency.rs  dynamic.rs
```

It authenticates via **Workload Identity read from the GKE metadata server** — the
mechanism §3 was about to propose building. It is reached in production code
(`services/credential.rs` → `build_secret_provider`,
`resolve_keychain_entry_with_meta`; `handlers/credentials.rs` → broker registry).

And it is **live on prod right now**:

```
noetl_secret_resolve_duration_seconds_bucket{provider="gcp",le="0.5"}  36
noetl_secret_residency_check_total{decision="allowed_no_policy"}       36
```

**36 GCP Secret Manager resolutions**, with residency checks. `duffel_token` is
already registered as type **`secret_manager`**.

So for keychain credentials the owner's directive is **already implemented and
in use**. What remains is smaller and sharper than this RFC first assumed.

---

## 2. Options — re-scoped around what already exists

§1.5 changes the question. There are **two tiers**, and only one of them is an
open problem.

### Tier 1 — keychain credentials: **already solved, one migration left**

`auth0_client`, `duffel_token`, `gcs_*`, `sf_test`, `ib_*`, `pg_*` — resolved at
execution time through the Secrets Wallet, which already speaks GCP Secret
Manager over Workload Identity and has done so 36 times on prod.

The only work here is **re-registering `auth0_client` from type `auth0` to type
`secret_manager`**, exactly as `duffel_token` already is. No new infrastructure,
no new code, no pod-spec change — a credential-record change plus an owner-run
`gcloud secrets create`. The playbooks are untouched: they reference the alias,
and the alias is the indirection that makes the backend swappable.

### Tier 2 — bootstrap secrets: the genuine gap

`NOETL_ENCRYPTION_KEY`, `POSTGRES_PASSWORD`, `NOETL_INTERNAL_API_TOKEN`.

These cannot use the wallet, and the reason is structural rather than
incidental: **the wallet needs Postgres to read the credential table, and
Postgres needs `POSTGRES_PASSWORD`.** A credential that the credential system
depends on cannot be stored in the credential system. Same for
`NOETL_ENCRYPTION_KEY`, which protects the stored credentials themselves. This
is a bootstrap problem, not an oversight.

So Tier 2 needs delivery *before* the process can reach its own machinery:

| option | verdict |
| :-- | :-- |
| **(a) Secret Manager CSI add-on**, mounted as files | **recommended.** Keeps the secret out of etcd — the actual security gain. Delivered by the kubelet before the container starts, so no startup network call and nothing to time out |
| **(b) External Secrets Operator** | rejected. Syncs SM → K8s Secret, so the secret **stays in etcd**; Secret Manager becomes the source of truth but not the storage boundary. An operator to run on a security-critical path for most of the benefit forgone |
| **(c) app-level SM client at startup** | rejected **for Tier 2 specifically**. It is already the Tier-1 answer and works well there — but at boot it would put a blocking network dependency in front of Postgres connect. #297 is a fresh reminder of what an unbounded startup dependency costs. The CSI file is present or absent; there is no call to hang |

### Recommendation

- **Tier 1:** re-register `auth0_client` as `secret_manager`. Uses the proven path.
- **Tier 2:** GKE Secret Manager CSI add-on + a small shared Rust helper honouring
  `<VAR>_FILE` (`<VAR>_FILE` if set and readable → else `<VAR>` → else today's
  error). The convention is well-trodden (Docker secrets, the official Postgres
  images), and **both paths coexist**, which is what makes every stage
  reversible: until `_FILE` is set, each workload behaves exactly as today.

The revised migration set is therefore **3 workload-env secrets + 1 credential
re-registration** — not the wholesale re-plumbing the first draft implied.

## 3. Workload Identity + IAM — commands **for the owner to run**

Not run by me. I do not create or modify IAM, service accounts, or grants.

⚠ Use `--account=shastaratech@gmail.com` for `shastaratech-noetl-prod`. A
two-session "permission gate" once turned out to be the wrong gcloud account.

⚠ Never pass a secret value as a command-line argument — arguments reach shell
history and Cloud Audit Logs argument capture. Pipe from a file and shred it.

```bash
PROJECT=shastaratech-noetl-prod
ACCOUNT=shastaratech@gmail.com
NS=noetl
```

### Tier 1 — the Auth0 client secret (one credential, proven path)

`noetl-server-rust` already runs as `noetl-result-tier@…` via Workload Identity,
and that identity already resolves `duffel_token` from Secret Manager 36 times
over. So this is a secret plus one grant.

```bash
gcloud secrets create noetl-auth0-client-secret --replication-policy=automatic   --project=$PROJECT --account=$ACCOUNT
# value added from a file, never inline:
#   gcloud secrets versions add noetl-auth0-client-secret --data-file=<path> #     --project=$PROJECT --account=$ACCOUNT && shred -u <path>

gcloud secrets add-iam-policy-binding noetl-auth0-client-secret   --member="serviceAccount:noetl-result-tier@$PROJECT.iam.gserviceaccount.com"   --role="roles/secretmanager.secretAccessor"   --project=$PROJECT --account=$ACCOUNT
```

Then `auth0_client` is re-registered as type `secret_manager` pointing at that
secret — a NoETL credential-record change, held until approval.

### Tier 2 — bootstrap secrets (new plumbing)

```bash
# cluster add-on, one-time
gcloud services enable secretmanager.googleapis.com   --project=$PROJECT --account=$ACCOUNT
gcloud container clusters update noetl-prod-autopilot   --region=us-central1 --project=$PROJECT --account=$ACCOUNT   --enable-secret-manager

# the three bootstrap secrets
for S in noetl-internal-api-token noetl-encryption-key noetl-postgres-password; do
  gcloud secrets create $S --replication-policy=automatic     --project=$PROJECT --account=$ACCOUNT
done

# the system pool has no GSA today (§1.3)
gcloud iam service-accounts create noetl-system-pool   --display-name="NoETL system pool (Secret Manager reader)"   --project=$PROJECT --account=$ACCOUNT

# accessor PER SECRET — never project-wide secretmanager.admin
for S in noetl-internal-api-token noetl-encryption-key noetl-postgres-password; do
  gcloud secrets add-iam-policy-binding $S     --member="serviceAccount:noetl-result-tier@$PROJECT.iam.gserviceaccount.com"     --role="roles/secretmanager.secretAccessor"     --project=$PROJECT --account=$ACCOUNT
done
gcloud secrets add-iam-policy-binding noetl-internal-api-token   --member="serviceAccount:noetl-system-pool@$PROJECT.iam.gserviceaccount.com"   --role="roles/secretmanager.secretAccessor"   --project=$PROJECT --account=$ACCOUNT

# bind KSA -> GSA
gcloud iam service-accounts add-iam-policy-binding   noetl-system-pool@$PROJECT.iam.gserviceaccount.com   --role="roles/iam.workloadIdentityUser"   --member="serviceAccount:$PROJECT.svc.id.goog[$NS/noetl-worker-system-pool]"   --project=$PROJECT --account=$ACCOUNT
```

The KSA annotation (`iam.gke.io/gcp-service-account`) is an ordinary manifest
change and lands via the ops repo — held until approval.

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

**The item-3 fold is still correct.** `NOETL_AUTH0_AUDIENCE` is a public Auth0
client id, confirmed four independent ways (browser-served `auth.js` ConfigMap;
`VITE_AUTH0_CLIENT_ID` compiled into the GUI bundle; `DEFAULT_AUTH0_CLIENT_ID` in
travel's `authConfig.ts`; a committed plaintext default in the
`get_auth0_token` playbook). `server-rust-deployment-prod.yaml` can be folded
into the reconcile **as a literal**, matching the ConfigMap. That closes item 3
and needs no Secret Manager work.

**Order matters.** ops#272 / #273 made a `kubectl apply` a proven no-op. Tier 2
changes the pod spec (CSI volume, mount, `_FILE` env, KSA annotation), so **each
stage must re-capture and re-prove the no-op diff in the same change set**, or
this RFC reintroduces the #267 drift that work removed. Tier 1 touches no
manifest at all.

**Sequencing.** Tier 1 first — it is one credential record on a proven path, and
it delivers the owner's directive for the Auth0 secret immediately. Tier 2
second, staged per §4.

**Out of scope.** Genuine third-party business credentials stay keychain-resolved
per `execution-model.md`; their *backend* is already Secret Manager where
registered as `secret_manager`, which is the correct shape — the alias is the
boundary, the backend is an implementation detail.

**Not established.** Rotation cadence; whether `noetl-secret/POSTGRES_PASSWORD`
is live or orphaned (§1.1); whether the user pool and writer should carry an
internal API token at all (§1.3); and whether the other 18 keychain credentials
should also move to `secret_manager` type, which is a per-credential decision
rather than a blanket one.

## Related

- `agents/rules/execution-model.md` — keychain vs platform credentials
- `agents/rules/safety.md` — public repo; no secrets committed
- noetl/ai-meta#267 — the IaC reconcile this must not undo
- noetl/ai-meta#297 — why a blocking startup dependency is treated as a hazard
