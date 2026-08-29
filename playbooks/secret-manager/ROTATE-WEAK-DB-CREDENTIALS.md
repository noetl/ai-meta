# Rotate the weak + public database credentials: `postgres`, `demo`, `auth`

**Owner runs every step. The agent handles no credential values.**
All commands carry `--project=shastaratech-noetl-prod --account=shastaratech@gmail.com`.

Tracks noetl/ai-meta#310 and noetl/ai-meta#300.

## Why

Three Cloud SQL users on `noetl-shared-pg` have trivially weak passwords, and two
of them are also published:

| user | weak | published | notes |
| :-- | :-- | :-- | :-- |
| **`postgres`** (SUPERUSER) | yes | 🔴 yes — `secret.yaml`'s `POSTGRES_PASSWORD` key | **shares one value with `demo`** |
| `demo` | yes | 🔴 yes — same key | |
| `auth` | yes | not in `secret.yaml` | password ALSO lives in the `pg_auth` keychain credential |

Both properties hold independently: these need rotating even ignoring the exposure.

## ⚠ THE STEP THAT BREAKS ROTATIONS — read before starting

On 2026-08-28 the `noetl` rotation appeared to fail against Cloud SQL. It had not.
**pgbouncer authenticates clients itself**, against
`auth_file=/etc/pgbouncer/userlist.txt` — plaintext entries that the `edoburu`
entrypoint generates from the `DATABASE_URLS` env var.

Change Cloud SQL and Secret Manager only, and pgbouncer rejects the new password
**before Postgres ever sees it**, with `SASL authentication failed` — an error that
reads exactly like a Cloud SQL mismatch and sends you to the wrong place. That cost
two successful `UPDATE_USER` operations and ~80 minutes of a crashlooping control
plane.

**Every user below needs its `userlist.txt` line updated and a `SIGHUP`.**
Use SIGHUP, never a restart: a restart drops the pool *and* regenerates the userlist
from the unchanged `DATABASE_URLS`, i.e. it reinstates the old password. A restart
here is a regression plus an outage.

## ⚠ Where each credential lives — this determines the step count

| user | Cloud SQL | pgbouncer userlist | Secret Manager | keychain (`noetl.credential`) |
| :-- | :-- | :-- | :-- | :-- |
| `postgres` | yes | yes | **none today** | no |
| `demo` | yes | yes | **none today** | `pg_demo` |
| `auth` | yes | yes | **none today** | **`pg_auth`** ← the auth fast-path resolves this |

Only `noetl-postgres-password` exists in Secret Manager. These three have no SM
secret, so a new one is needed per user *if* you want them managed the same way.
They are not read from files by any workload today, so SM is optional for them —
but it is the direction of travel, and `auth` in particular is worth it.

⚠ **`auth` is the highest-risk of the three.** Its password is stored in the
`pg_auth` keychain credential, which the server's synchronous auth fast-path
(noetl/ai-meta#168) resolves on every login. Rotate Cloud SQL without updating
`pg_auth` and **logins break**.

## Ordering

Do them in this order — least blast radius first, so a mistake is cheap:

1. **`demo`** — lowest risk; `demo_noetl` database, not the control plane.
2. **`postgres`** — superuser; nothing in the platform authenticates as it today
   (the server uses `noetl`), so it is mostly an administrative credential.
3. **`auth`** — last, because it touches the login path and needs the keychain
   update in the same window.

⚠ `demo` and `postgres` currently **share one value**. Give them **different**
passwords, or rotating one leaves the shared secret live.

---

## Per-user procedure

Repeat for `<USER>` ∈ {`demo`, `postgres`, `auth`}, one at a time, verifying between.

### 1. Generate and verify — before touching anything

```bash
umask 077
PW=$(mktemp /tmp/pg-<USER>.XXXXXX)
openssl rand -base64 32 | tr -d '\n' > "$PW"
wc -c < "$PW"                                  # expect 44
shasum -a 256 "$PW" | cut -c1-12               # note this digest
tr -d '\n\r' < "$PW" | shasum -a 256 | cut -c1-12   # must MATCH the line above
```

The two digests must agree — that is the trailing-newline gate that the first
`noetl` attempt lacked.

### 2. Set it on Cloud SQL

Preferred (no paste at all — this is the path that worked):

```bash
python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"password":open(sys.argv[2]).read()}))' <USER> "$PW" > /tmp/body.json
chmod 600 /tmp/body.json
curl -sS -X PUT \
  -H "Authorization: Bearer $(gcloud auth print-access-token --account=shastaratech@gmail.com)" \
  -H "Content-Type: application/json" --data-binary @/tmp/body.json \
  "https://sqladmin.googleapis.com/v1/projects/shastaratech-noetl-prod/instances/noetl-shared-pg/users?name=<USER>&host=" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("status") or d.get("error",{}).get("message"))'
# expect PENDING or DONE
shred -u /tmp/body.json 2>/dev/null || rm -f /tmp/body.json
```

Alternative: `pbcopy < "$PW"` then
`gcloud sql users set-password <USER> --instance=noetl-shared-pg --prompt-for-password …`
and paste. ⚠ Never `--password="$(cat …)"` — that puts the value in argv where
`ps` shows it.

Confirm it landed:

```bash
gcloud sql operations list --instance=noetl-shared-pg --limit=3 \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com \
  --format='table(operationType,status,endTime)'
```

### 3. ⚠ Update the pgbouncer userlist + RELOAD — the step that is always forgotten

```bash
kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  cp /etc/pgbouncer/userlist.txt /etc/pgbouncer/userlist.txt.bak

kubectl -n postgres exec -i deploy/pgbouncer -c pgbouncer -- sh -c '
  read -r NEW
  awk -v u="\"<USER>\"" -v p="$NEW" '"'"'$1==u {print u " \"" p "\""; next} {print}'"'"' \
    /etc/pgbouncer/userlist.txt > /tmp/ul.new &&
  cat /tmp/ul.new > /etc/pgbouncer/userlist.txt && rm -f /tmp/ul.new
' < "$PW"

# every other user must be untouched — names + short prefixes only
kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  awk '{printf "%s %s...\n", $1, substr($2,1,6)}' /etc/pgbouncer/userlist.txt

# RELOAD — re-reads auth_file, does NOT drop pooled connections
kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- kill -HUP 1
```

⚠ Pass `-c pgbouncer`. Without it you land in the `cloud-sql-proxy` sidecar, whose
logs look healthy no matter what pgbouncer is doing.

### 4. `auth` ONLY — update the `pg_auth` keychain credential

The auth fast-path resolves `pg_auth` on every login, so this must happen in the
same window as step 2 or **logins break**.

```bash
TOK=$(kubectl -n noetl get secret noetl-internal-api-token -o jsonpath='{.data.token}' | base64 -d)
# inspect the CURRENT shape first (keys only, no values)
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- sh -c \
  "wget -qO- -T20 --header='Authorization: Bearer $TOK' \
   'http://127.0.0.1:8082/api/credentials/pg_auth?include_data=true'" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sorted((d.get("data") or {}).keys()))'
# expect: ['db_host','db_name','db_password','db_port','db_user']  (db_user=auth)
```

Re-POST the credential with the same fields and the new `db_password`, via
`POST /api/credentials`. Build the body from the file so the value never reaches
argv — same `python3 -c … open(PW).read()` pattern as step 2.

Also check whether `pg_auth_backup_20260814` and `pg_auth_user` need the same
treatment, or should be pruned (they are part of noetl/ai-meta#301).

### 5. Optional — put it in Secret Manager

```bash
gcloud secrets create noetl-<USER>-password --replication-policy=automatic \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
gcloud secrets versions add noetl-<USER>-password --data-file="$PW" \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
```

No workload reads these today, so this is for management consistency rather than
runtime. It becomes load-bearing only if the durable pgbouncer fix below moves
`DATABASE_URLS` to file/secret references.

### 6. Verify before moving to the next user

```bash
# control plane unaffected (it authenticates as `noetl`, not these)
kubectl -n noetl get pod -l app=noetl-server-rust
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- wget -qO- 127.0.0.1:8082/health

# pgbouncer not rejecting
kubectl -n postgres logs deploy/pgbouncer -c pgbouncer --since=10m | grep -iE 'auth|error' | tail -20

# auth ONLY — a real login must still work end to end
```

### 7. Clean up

```bash
shred -u "$PW" 2>/dev/null || rm -f "$PW"
pbcopy < /dev/null
```

---

## ⚠ The durable fix, and why the reload alone is not enough

`userlist.txt` is regenerated from `DATABASE_URLS` at every pgbouncer start. So
**every step-3 edit above is ephemeral** — one restart, eviction or node move and
all four users revert to their old passwords, silently, until something fails to
authenticate.

The durable fix is to stop keeping plaintext credentials in `DATABASE_URLS`:

- **Minimum:** update `DATABASE_URLS` to the new values. Restarts pgbouncer, drops
  the pool — a planned change, and only after every user above is rotated, or you
  will reinstate a mix of old and new.
- **Better:** source the userlist from a mounted Secret or a CSI-projected file
  rather than Deployment env, so rotation is a file update and a SIGHUP, and no
  credential sits in a Deployment spec at all.

Until that lands, treat this rotation as **provisional**: correct in the running
process, reverting on the next restart.

## Rollback

Per user: set the previous password back via step 2, restore the userlist from
`userlist.txt.bak`, `SIGHUP`. ⚠ For `demo`/`postgres` the previous value is the
**published** one, so a rollback re-opens that exposure — break-glass only.
