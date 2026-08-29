# Extending the durable CSI seeding to `demo`, `auth` and `postgres`

**Status: staged and inert. Nothing applied, no secret created, no IAM touched.**

## The risk this closes

The #311 fix seeds **`noetl` only** from Secret Manager. The other three users
still come from the inline `DATABASE_URLS` literal, which means **their SIGHUP
reload is still ephemeral**: the next Autopilot reschedule regenerates their
userlist entries from the stale inline value.

That is the exact #311 failure mode, still live for three users — including
`postgres`, the superuser. It has not bitten yet only because those three have
not been rotated, so the stale value still happens to be correct. **The moment
they are rotated, the clock starts.**

Which is why this should land *before* the weak-credential rotation
(`ROTATE-WEAK-DB-CREDENTIALS.md`), not after.

## What is already staged

`pgbouncer-patch.yaml` (and the declared manifest in `noetl/ops`) now seeds each
user **only when its mounted file exists**:

```sh
seed noetl    /mnt/db-secrets/postgres-password
seed demo     /mnt/db-secrets/demo-password
seed auth     /mnt/db-secrets/auth-password
seed postgres /mnt/db-secrets/superuser-password
```

**This is a no-op today.** The live SecretProviderClass provides only
`postgres-password`, so `noetl` is seeded exactly as it is now and the other
three fall through to `DATABASE_URLS` unchanged.

Kind-proven, without any live secret:

| arm | result |
| :-- | :-- |
| one key mounted (prod today) | `noetl` 5 chars from the mount; `demo`/`auth` 6 chars from `DATABASE_URLS`; client auth `AUTH_OK` |
| four keys mounted | `noetl` 5, `demo` **18**, `auth` **20**, `postgres` **16** — all from the mount, and the mount **wins** over the 6-char inline values |
| pod deleted, four keys mounted | identical userlist, `AUTH_OK_AFTER_RESTART` |

The differing lengths are the evidence: they can only have come from the mount.

## ⚠ Why the SecretProviderClass is a SECOND file, not an edit

`secretproviderclass-all-users.yaml` declares all four secrets and is
**deliberately not applied**.

The CSI driver fails the **mount** when a declared secret cannot be fetched, and
a failed mount leaves the pod in `ContainerCreating`. Applying it before the
secrets exist — or before IAM covers them — would take the pooler down: the same
outage class as #311, reached from the other direction.

A second class also makes the switch a one-line, reversible change to the
Deployment's volume reference rather than a mutation of the object prod currently
depends on.

---

# Owner-run prerequisites

Everything below handles credential values or IAM. **The agent does none of it.**

## 1. Create the three Secret Manager secrets

The values are the *current* `demo` / `auth` / `postgres` passwords, so this step
changes nothing functionally — it moves where they are read from. (If you would
rather rotate at the same time, do
`ROTATE-WEAK-DB-CREDENTIALS.md` **after** this lands, so the rotation lands in
one place instead of two.)

```bash
umask 077
for u in demo auth superuser; do
  f=$(mktemp /tmp/noetl-$u.XXXXXX)
  printf '%s' "PASTE_THE_CURRENT_PASSWORD_FOR_$u" > "$f"   # no trailing newline
  gcloud secrets create "noetl-${u}-password" --replication-policy=automatic \
    --project=shastaratech-noetl-prod --account=shastaratech@gmail.com 2>/dev/null || true
  gcloud secrets versions add "noetl-${u}-password" --data-file="$f" \
    --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
  shred -u "$f" 2>/dev/null || rm -f "$f"
done
```

⚠ **No trailing newline.** `printf '%s'`, not `echo`. The seeding script writes
the file's bytes verbatim into the userlist; a trailing `\n` becomes part of the
password and authentication fails with `SASL authentication failed` — which
reads exactly like a wrong password and sends you to the wrong place.

Verify the lengths without printing values:

```bash
for u in demo auth superuser; do
  printf '%s -> ' "$u"
  gcloud secrets versions access latest --secret="noetl-${u}-password" \
    --project=shastaratech-noetl-prod --account=shastaratech@gmail.com | wc -c
done
```

Compare against what pgbouncer holds today (currently 4 chars each):

```bash
kubectl --context "$CTX" -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  awk '{printf "%s -> %d chars\n", $1, length($2)-2}' /etc/pgbouncer/userlist.txt
```

**They must match.** A mismatch means the wrong value or a stray newline.

## 2. Extend the IAM binding to the three new secrets

The GSA already has `secretAccessor` on `noetl-postgres-password` (granted for
#311). Each secret carries its own policy, so it must be granted per secret:

```bash
for u in demo auth superuser; do
  gcloud secrets add-iam-policy-binding "noetl-${u}-password" \
    --member="serviceAccount:noetl-cloudsql-proxy@shastaratech-noetl-prod.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
done
```

Verify (the role is `secretAccessor` — a substring match on "accessor" gives a
false negative):

```bash
for u in demo auth superuser; do
  echo "== noetl-${u}-password"
  gcloud secrets get-iam-policy "noetl-${u}-password" \
    --project=shastaratech-noetl-prod --account=shastaratech@gmail.com \
    --format="table(bindings.role, bindings.members)"
done
```

## 3. Apply — after 1 and 2 both verify

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$CTX" apply -f secretproviderclass-all-users.yaml
kubectl --context "$CTX" -n postgres patch deploy pgbouncer --type=json -p='[
  {"op":"replace",
   "path":"/spec/template/spec/volumes/0/csi/volumeAttributes/secretProviderClass",
   "value":"pgbouncer-db-secrets-all"}
]'
kubectl --context "$CTX" -n postgres rollout status deploy/pgbouncer --timeout=5m
```

⚠ Confirm index `0` is the `db-secrets` volume before running the patch:

```bash
kubectl --context "$CTX" -n postgres get deploy pgbouncer \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}'
```

## 4. Verify

```bash
kubectl --context "$CTX" -n postgres logs deploy/pgbouncer -c pgbouncer | grep 'userlist:'
# expect four "seeded ... from CSI mount" lines and no "no mount for" lines

kubectl --context "$CTX" -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  awk '{printf "%s -> %d chars\n", $1, length($2)-2}' /etc/pgbouncer/userlist.txt
# every length must match the Secret Manager lengths from step 1

kubectl --context "$CTX" -n noetl get pods
# the platform must stay healthy; noetl must still read 44 chars
```

## 5. Rollback — one command

```bash
kubectl --context "$CTX" -n postgres patch deploy pgbouncer --type=json -p='[
  {"op":"replace",
   "path":"/spec/template/spec/volumes/0/csi/volumeAttributes/secretProviderClass",
   "value":"pgbouncer-db-secrets"}
]'
```

Back to the single-secret class; the seeding script falls through to
`DATABASE_URLS` for the other three exactly as today. ⚠ Unlike #311's rollback,
this one **is** a safe resting state — it is the current configuration.

## What this does not do

It does not rotate anything. `demo`, `auth` and `postgres` keep their existing
(4-character) passwords; this only changes where pgbouncer reads them from. The
rotation is `ROTATE-WEAK-DB-CREDENTIALS.md`, and it gets materially simpler once
this has landed — the userlist step disappears for all four users.
