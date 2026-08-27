# Owner-run commands — Secret Manager migration

**Run by the owner only.** I do not create or modify IAM, service accounts,
grants, or secret values, and I never see the values.

Two independent blocks. **Block A** unblocks the `auth0_client` migration.
**Block B** unblocks Tier 2. They can be run in either order, or A alone.

## The project — determined from the live setup, not assumed

**All prod secrets go in `shastaratech-noetl-prod`** (project number
`986938120811`). Everything already colocates there:

| thing | project | how established |
| :-- | :-- | :-- |
| GKE cluster | `shastaratech-noetl-prod` | context `gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot` |
| `noetl-result-tier@…` (server GSA) | `shastaratech-noetl-prod` | KSA annotation `iam.gke.io/gcp-service-account` |
| `noetl-worker-mcp@…` (worker GSA) | `shastaratech-noetl-prod` | same |
| the secrets the wallet already resolves | `shastaratech-noetl-prod` | `duffel-api-test` = `projects/986938120811/secrets/duffel-api-test` |

So this **extends the proven path** — no cross-project IAM, and the Workload
Identity pool (`shastaratech-noetl-prod.svc.id.goog`) already matches.

⚠⚠ **The ops mirror disagrees, and it is wrong.**
`repos/ops/automation/agents/mcp/duffel.yaml` defaults `google_project` to
`noetl-demo-19700101` — the **retired** project (noetl/ai-meta#234). The **live
registered** playbook `automation/agents/mcp/duffel` **v19** uses
`shastaratech-noetl-prod`. This is the noetl/ai-meta#295 pattern again: the
inline/live copy is authoritative and the mirror has drifted. Do not take the
project from the ops repo.

⚠ The retired project still holds secrets with **colliding names**, including a
`NOETL_ENCRYPTION_KEY`. A grant or reference aimed at the wrong project fails in
the worst way available — it resolves *something*, or nothing, without saying
which project it looked in.

**Do not scatter prod secrets** into `shastaratech-sandbox`, `-ai-lab`,
`-obs-prod`, `-youtube-prod`, `-web-*` or `-dns-prod`. Those are different
trust and blast-radius domains. Dev/kind secrets belong in
`shastaratech-noetl-dev`, kept separate from prod.

## Before you start

```bash
export PROJECT=shastaratech-noetl-prod      # <- determined above; do not change
export ACCOUNT=shastaratech@gmail.com
export NS=noetl
export REGION=us-central1
export CLUSTER=noetl-prod-autopilot

gcloud config list account --format='value(core.account)'   # WHO am I
gcloud projects describe $PROJECT --account=$ACCOUNT --format='value(projectNumber)'
# expect: 986938120811
```

⚠ **Every command below carries `--project=$PROJECT` explicitly.** A secret
created in the wrong project does not error — it simply never resolves, and the
failure surfaces far from its cause.

⚠ **Use `--account=$ACCOUNT`.** A two-session "permission gate" on
noetl/ai-meta#204 turned out to be the wrong gcloud account, not a missing
permission.

⚠ **Never pass a secret value as a command-line argument.** Arguments land in
shell history and in Cloud Audit Logs argument capture. Every command reads from
a file and shreds it.

⚠ **Do not paste any secret value into chat.** Nothing below asks you to.

## Block A — `auth0_client`

### ⚠ Most of this is already done

Checked against Secret Manager: **the secret already exists** in
`shastaratech-noetl-prod`.

```
NAME           CREATED
auth0_client   2026-08-27T01:59:45     version 1, state=enabled
```

So **A1 and A2 below are already satisfied** — and note the name is
`auth0_client` (underscore), not the `noetl-auth0-client-secret` this document
originally proposed. **Use the existing name.** Creating a second secret for the
same material would leave two sources of truth and a rotation that only updates
one.

**One thing is missing, and it is the thing that makes it work:**

```
$ gcloud secrets get-iam-policy auth0_client --project=$PROJECT
ROLE  MEMBERS
              <- empty. Nothing can read it.
```

### A3. Grant accessor on that secret to the server's existing GSA — **the only step needed**

```bash
gcloud secrets add-iam-policy-binding auth0_client \
  --member="serviceAccount:noetl-result-tier@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --project=$PROJECT --account=$ACCOUNT
```

⚠ Per-secret grant, deliberately. Never `roles/secretmanager.admin`, never
project-wide `secretAccessor`.

### A4. Confirm (safe — metadata only, never the value)

```bash
gcloud secrets get-iam-policy auth0_client \
  --project=$PROJECT --account=$ACCOUNT \
  --format='table(bindings.role,bindings.members)'
# expect: roles/secretmanager.secretAccessor  serviceAccount:noetl-result-tier@...

gcloud secrets versions list auth0_client \
  --project=$PROJECT --account=$ACCOUNT \
  --format='table(name,state,createTime)'
# expect: 1  enabled
```

### If A2 was NOT in fact done (a new secret, or a rotation)

```bash
umask 077
cat > /tmp/a0.secret          # paste the value, then Ctrl-D
gcloud secrets versions add auth0_client --data-file=/tmp/a0.secret \
  --project=$PROJECT --account=$ACCOUNT
shred -u /tmp/a0.secret       # macOS: rm -P /tmp/a0.secret
```

⚠ `cat > file` then Ctrl-D keeps the value out of shell history. `echo "$V" >`
does not.

**Then tell me "Block A done."** I run verify-before-flip: a temporary
`auth0_client_sm` alias, a live resolve check, and a negative control — and flip
`auth0_client` only if it passes.

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
