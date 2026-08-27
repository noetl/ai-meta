# Owner-run commands — Secret Manager migration

**Run by the owner only.** I do not create or modify IAM, service accounts,
grants, or secret values, and I never see the values.

Two independent blocks. **Block A** unblocks the `auth0_client` migration.
**Block B** unblocks Tier 2. They can be run in either order, or A alone.

## Before you start

```bash
export PROJECT=shastaratech-noetl-prod
export ACCOUNT=shastaratech@gmail.com
export NS=noetl
export REGION=us-central1
export CLUSTER=noetl-prod-autopilot

gcloud config list account --format='value(core.account)'   # sanity-check WHO you are
```

⚠ **Use `--account=$ACCOUNT`.** A two-session "permission gate" on
noetl/ai-meta#204 turned out to be the wrong gcloud account, not a missing
permission.

⚠ **Never pass a secret value as a command-line argument.** Arguments land in
shell history and in Cloud Audit Logs argument capture. Every command below
reads from a file, and shreds it afterwards.

⚠ **Do not paste any secret value into chat.** Nothing below asks you to, and I
have no need for any of these values at any point.

---

## Block A — `auth0_client` (the narrow migration)

### A1. Enable the API (idempotent; skip if already on)

```bash
gcloud services enable secretmanager.googleapis.com \
  --project=$PROJECT --account=$ACCOUNT
```

### A2. Create the secret and add the value from a file

The value is the **Auth0 application client secret** — the same value currently
stored inline in the NoETL credential alias `auth0_client`. Retrieve it from your
Auth0 dashboard (Applications → the app whose client id ends `…hbhbDN` → Client
Secret), or from wherever you hold it today.

```bash
gcloud secrets create noetl-auth0-client-secret \
  --replication-policy=automatic \
  --project=$PROJECT --account=$ACCOUNT

# write the value to a file — do NOT echo it, do NOT pass it with --data=
umask 077
cat > /tmp/a0.secret          # paste the value, then Ctrl-D
gcloud secrets versions add noetl-auth0-client-secret \
  --data-file=/tmp/a0.secret \
  --project=$PROJECT --account=$ACCOUNT
shred -u /tmp/a0.secret       # macOS: rm -P /tmp/a0.secret
```

⚠ `cat > file` then Ctrl-D keeps the value out of shell history. `echo "$V" >`
does not.

### A3. Grant accessor on **just this secret** to the server's existing GSA

`noetl-server-rust` already runs as `noetl-result-tier@…` via Workload Identity
and already resolves `duffel_token` from Secret Manager, so no new service
account or binding is needed — only this grant.

```bash
gcloud secrets add-iam-policy-binding noetl-auth0-client-secret \
  --member="serviceAccount:noetl-result-tier@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --project=$PROJECT --account=$ACCOUNT
```

⚠ Per-secret grant, deliberately. Never `roles/secretmanager.admin`, and never
project-wide `secretAccessor`.

### A4. Confirm (safe — prints metadata, never the value)

```bash
gcloud secrets describe noetl-auth0-client-secret \
  --project=$PROJECT --account=$ACCOUNT --format='value(name,createTime)'

gcloud secrets versions list noetl-auth0-client-secret \
  --project=$PROJECT --account=$ACCOUNT --format='table(name,state,createTime)'

gcloud secrets get-iam-policy noetl-auth0-client-secret \
  --project=$PROJECT --account=$ACCOUNT \
  --format='table(bindings.role,bindings.members)'
```

**Then tell me "Block A done."** I will run the verify-before-flip (temporary
`auth0_client_sm` alias, live resolve check, negative control) and only flip
`auth0_client` if it passes.

---

## Block B — Tier 2 bootstrap secrets (CSI + `_FILE`)

Unblocks prod stages 3–5 only. Stages 1–2 (inert helper, kind proof) need none
of this.

### B1. Enable the GKE Secret Manager add-on

```bash
gcloud container clusters update $CLUSTER \
  --region=$REGION --project=$PROJECT --account=$ACCOUNT \
  --enable-secret-manager
```

⚠ This is a **cluster-level** change and may trigger a control-plane update. It
adds the CSI driver; it changes no workload. Safe to run ahead of everything
else.

### B2. Create the three secrets (values from files)

Each value is what the matching Kubernetes Secret holds **today** — copy it from
there, so the two agree during the dual-run. Read it out yourself; I do not need
to see it.

```bash
for S in noetl-internal-api-token noetl-encryption-key noetl-postgres-password; do
  gcloud secrets create $S --replication-policy=automatic \
    --project=$PROJECT --account=$ACCOUNT
done

# per secret, one at a time:
umask 077
cat > /tmp/v.secret           # paste, Ctrl-D
gcloud secrets versions add <SECRET_NAME> --data-file=/tmp/v.secret \
  --project=$PROJECT --account=$ACCOUNT
shred -u /tmp/v.secret
```

Mapping from the live Kubernetes Secrets (**by reference**):

| GCP Secret Manager secret | current K8s source |
| :-- | :-- |
| `noetl-internal-api-token` | `noetl-internal-api-token` / key `token` |
| `noetl-encryption-key` | `noetl-secret` / key `NOETL_ENCRYPTION_KEY` |
| `noetl-postgres-password` | `noetl-secret` / key `NOETL_PASSWORD` |

⚠ Note the third: the env var is `POSTGRES_PASSWORD` but the **key** is
`NOETL_PASSWORD`. `noetl-secret` also holds an unused key literally named
`POSTGRES_PASSWORD` that nothing binds — do **not** copy that one. See
noetl/ai-meta#300.

### B3. Service account for the system pool

`noetl-worker-system-pool` and `-shard1` have **no** GSA today, and they are the
two workloads that hold the internal API token.

```bash
gcloud iam service-accounts create noetl-system-pool \
  --display-name="NoETL system pool (Secret Manager reader)" \
  --project=$PROJECT --account=$ACCOUNT
```

### B4. Per-secret accessor grants — least privilege

```bash
# the server needs all three
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
```

### B5. Bind KSA → GSA (Workload Identity)

**Confirmed against the live cluster: both system pools share one Kubernetes
service account**, `noetl-worker-system-pool`. So this is a single binding, not
two.

```
noetl-worker-system-pool          KSA=noetl-worker-system-pool
noetl-worker-system-pool-shard1   KSA=noetl-worker-system-pool   <- same KSA
```

```bash
gcloud iam service-accounts add-iam-policy-binding   noetl-system-pool@$PROJECT.iam.gserviceaccount.com   --role="roles/iam.workloadIdentityUser"   --member="serviceAccount:$PROJECT.svc.id.goog[$NS/noetl-worker-system-pool]"   --project=$PROJECT --account=$ACCOUNT
```

⚠ One consequence worth knowing before you run it: because the KSA is shared,
this grant reaches **both** system pools at once. There is no way to give the
main pool Secret Manager access without also giving it to shard1 unless they are
split onto separate KSAs first. For these two — same image, same role, same
secret — sharing is appropriate.

ℹ️ `noetl-cmdbus-writer` has **no** service account set (it runs as `default`)
and needs none here: it holds no secret-sourced env.

### B6. Confirm

```bash
for S in noetl-internal-api-token noetl-encryption-key noetl-postgres-password; do
  echo "== $S"
  gcloud secrets get-iam-policy $S --project=$PROJECT --account=$ACCOUNT \
    --format='table(bindings.role,bindings.members)'
done
gcloud container clusters describe $CLUSTER --region=$REGION \
  --project=$PROJECT --account=$ACCOUNT \
  --format='value(secretManagerConfig.enabled)'
```

**Then tell me "Block B done."**

---

## Rollback of these commands

Nothing here changes a running workload, so rollback is only cleanup:

```bash
gcloud secrets delete <SECRET_NAME> --project=$PROJECT --account=$ACCOUNT
gcloud secrets remove-iam-policy-binding <SECRET_NAME> --member=... --role=... \
  --project=$PROJECT --account=$ACCOUNT
gcloud iam service-accounts delete noetl-system-pool@$PROJECT.iam.gserviceaccount.com \
  --project=$PROJECT --account=$ACCOUNT
gcloud container clusters update $CLUSTER --region=$REGION \
  --project=$PROJECT --account=$ACCOUNT --no-enable-secret-manager
```

⚠ Do **not** delete a secret that a live workload already reads. Cut the
workload back to `secretKeyRef` first (see `CHANGES.md`).
