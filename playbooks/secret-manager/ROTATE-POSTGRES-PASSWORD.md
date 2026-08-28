# Rotate the prod Postgres password (noetl/ai-meta#310, #304)

**Run by the owner.** The agent does not handle credential values.

Every command carries `--project=shastaratech-noetl-prod --account=shastaratech@gmail.com`.

## Why

The current password is committed in the **public** `noetl/ops` repository and, by
sha256, matches the live value. Removing it from the repo (ops#285) did **not** end
the exposure — git history is public and stays public. **Only this rotation does.**

## Before you start — three facts that shape the procedure

1. **There is no zero-downtime path.** Cloud SQL's dual-password flags
   (`--retain-password` / `--discard-dual-password`) are **MySQL 8.0 only**; this
   instance is `POSTGRES_15`. A Postgres user has exactly one password, so the old
   one dies the instant the new one is set. Steps 3→4 must run back to back.
2. **The window is between step 3 and pods becoming Ready** (~1–2 min). Existing
   pooled connections through pgbouncer are already authenticated and may survive;
   *new* connections fail until the roll completes.
3. **The same string was also the NATS password and the Jupyter token** in the
   repo. Verified in the cluster: **neither NATS nor Jupyter is deployed** (checked
   across all 20 namespaces), so there is nothing to rotate for them and nothing
   breaks. Their exposure is latent, not live.
   ⚠ The residual this leaves is **reuse outside this cluster** — a laptop, another
   cluster, a personal NATS or Jupyter. Rotation here does not touch those. Before
   calling this closed, answer: *where else was this string used?*
   ⚠ And note the wording: rotation means "the published value no longer works for
   Postgres", **not** "the exposure is closed". The string stays public permanently
   — the ecosystem is public by design and visibility is not a lever.

## Value safety

- The new value is generated **into a file**, never echoed.
- `gcloud secrets versions add --data-file=` keeps it off the command line.
- `gcloud sql users set-password --prompt-for-password` reads it with echo
  disabled, so it never enters argv or shell history.
  ⚠ The alternative, `--password="$(cat …)"`, puts the value in argv where any
  local user can see it via `ps`. **Do not use it.**

---

## 1. Generate the new password into a file

```bash
umask 077
NEWPW=$(mktemp /tmp/noetl-pg-pw.XXXXXX)
openssl rand -base64 32 | tr -d '\n' > "$NEWPW"
wc -c < "$NEWPW"     # sanity: expect 44. Do NOT cat the file.
echo "staged at $NEWPW"
```

## 2. Add the new Secret Manager version FIRST

Nothing consumes it yet — pods still hold the old value and keep working. Doing
this before touching Cloud SQL means the new value is already in place when you
need it, shortening the window in step 4.

```bash
gcloud secrets versions add noetl-postgres-password \
  --data-file="$NEWPW" \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com

gcloud secrets versions list noetl-postgres-password \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com --limit=3
```

Note the new version number. The SecretProviderClass reads `versions/latest`, so
the next pod mount picks it up automatically.

## 3. ⚠ Set it on the Cloud SQL user — THE WINDOW OPENS HERE

Paste the value from the file at the prompt (echo is disabled).

```bash
gcloud sql users set-password noetl \
  --instance=noetl-shared-pg \
  --prompt-for-password \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
```

**Go straight to step 4.** Do not pause here.

## 4. Roll the workloads so they mount the new version

```bash
kubectl -n noetl rollout restart deploy/noetl-server-rust
kubectl -n noetl rollout status  deploy/noetl-server-rust --timeout=8m
```

The system pools do not read the Postgres password; the control plane is the only
consumer. Restart them only if step 5 shows a problem.

## 5. Verify — the window is closed only when these pass

```bash
# (a) the pod mounted the new value: source must be "file"
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  wget -qO- 127.0.0.1:8082/metrics | grep 'secret_source_total.*POSTGRES_PASSWORD'
# expect: source="file" 1

# (b) health
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  wget -qO- 127.0.0.1:8082/health

# (c) THE REAL GATE — a live DB read. Health alone can pass without Postgres.
TOK=$(kubectl -n noetl get secret noetl-internal-api-token -o jsonpath='{.data.token}' | base64 -d)
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- sh -c \
  "wget -qO- -T25 --header='Authorization: Bearer $TOK' 'http://127.0.0.1:8082/api/executions?limit=3'"
# expect: a JSON array of execution rows

# (d) the boot log shows the pool built AFTER the file was read
kubectl -n noetl logs deploy/noetl-server-rust -c noetl-server --since=10m \
  | grep -E 'bootstrap secret source|connection pool created'

# (e) end-to-end
kubectl -n noetl exec deploy/noetl-server-rust -c noetl-server -- sh -c \
  "wget -qO- -T40 --header='Authorization: Bearer $TOK' --header='Content-Type: application/json' \
   --post-data='{\"path\":\"tests/e2e_probe\"}' 'http://127.0.0.1:8082/api/execute'"
# then poll /api/executions for that id — expect COMPLETED, 13 events
```

### ⚠ pgbouncer — THIS IS THE STEP THAT BREAKS THE ROTATION

**Correcting this section, which was wrong and cost a live incident on 2026-08-28.**

It previously said pgbouncer "should pass client credentials through to Postgres
rather than storing its own copy". **That is false.** The inference came from
finding no auth file — while the `kubectl exec` had silently landed in the
`cloud-sql-proxy` sidecar instead of the `pgbouncer` container, because no `-c` was
given. Wrong container, absent file, confident wrong conclusion.

What is actually running in `deploy/pgbouncer`:

```ini
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt      # PLAINTEXT entries, not SCRAM verifiers
```

`userlist.txt` holds one line per user — `"noetl" "<password>"` — and the
`edoburu` entrypoint **generates it from the `DATABASE_URLS` env var** at
container start.

**Consequence: pgbouncer authenticates the client itself.** Change the password in
Cloud SQL and Secret Manager only, and the new pod presents the new value,
pgbouncer rejects it against the stale userlist, and Postgres never sees the
attempt. The error is `SASL authentication failed`, which reads exactly like a
Cloud SQL mismatch and sends you to the wrong place. On 2026-08-28 that cost two
successful `UPDATE_USER` operations and ~80 minutes of a crashlooping control plane
before the real cause was found.

**So step 3 is not complete until the userlist is updated too.** Do this right
after `set-password`, before or alongside the pod roll:

```bash
kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  cp /etc/pgbouncer/userlist.txt /etc/pgbouncer/userlist.txt.bak

# rewrite ONLY the target user's line; value arrives on stdin, never on argv
kubectl -n postgres exec -i deploy/pgbouncer -c pgbouncer -- sh -c '
  read -r NEW
  awk -v p="$NEW" '"'"'$1=="\"noetl\"" {print "\"noetl\" \"" p "\""; next} {print}'"'"' \
    /etc/pgbouncer/userlist.txt > /tmp/ul.new &&
  cat /tmp/ul.new > /etc/pgbouncer/userlist.txt && rm -f /tmp/ul.new
' < "$NEWPW"

# confirm the OTHER users are untouched (names + short prefixes only)
kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  awk '{printf "%s %s...\n", $1, substr($2,1,6)}' /etc/pgbouncer/userlist.txt

# RELOAD — re-reads auth_file and does NOT drop pooled connections
kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- kill -HUP 1
```

Prefer **SIGHUP over a restart**: a restart drops the pool *and* regenerates the
userlist from the unchanged `DATABASE_URLS`, i.e. it puts the stale password back.
A restart is not a fix here — it is a regression plus an outage.

**⚠ The reload is ephemeral.** Any later pgbouncer restart regenerates
`userlist.txt` from `DATABASE_URLS`. The durable fix is to update `DATABASE_URLS`
on the Deployment — which *does* restart pgbouncer and drop the pool, so schedule
it as a planned change once the server is already on the new value. Better still,
move those credentials out of Deployment env entirely; they are plaintext there
today, for every user.

Verify pgbouncer is not the one rejecting:

```bash
kubectl -n postgres logs deploy/pgbouncer -c pgbouncer --since=10m | grep -iE 'auth|password|error' | tail -20
```

⚠ Pass `-c pgbouncer`. Without it you get the `cloud-sql-proxy` sidecar, whose
logs look healthy no matter what pgbouncer is doing — the exact mistake that
produced the wrong conclusion above.

## 6. Rollback — only possible by setting the old password back

There is no "previous version" to roll to on the Postgres side; the old password is
gone the moment step 3 runs. To roll back you must set the **old** value again:

```bash
gcloud sql users set-password noetl --instance=noetl-shared-pg --prompt-for-password \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
# paste the OLD value, then:
kubectl -n noetl rollout undo deploy/noetl-server-rust
```

⚠ The old value is the exposed one. Rolling back **re-opens the exposure**, so treat
it as a break-glass step and re-run the rotation promptly.

Retrieve the old value from Secret Manager if needed — do not read it from the repo:

```bash
gcloud secrets versions list noetl-postgres-password \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
# then access the PREVIOUS version number explicitly
```

## 7. The orphan key (noetl/ai-meta#300) — cheap, do it after

`noetl-secret` carries a `POSTGRES_PASSWORD` key that **nothing binds** (the server
binds `NOETL_PASSWORD`). It is a *different* value and it is also committed. Since
nothing reads it, delete the key rather than rotating it:

```bash
kubectl -n noetl get secret noetl-secret -o jsonpath='{.data}' | tr ',' '\n'   # inspect first
kubectl -n noetl patch secret noetl-secret --type=json \
  -p='[{"op":"remove","path":"/data/POSTGRES_PASSWORD"}]'
```

⚠ Do **not** delete the whole `noetl-secret`. It remains the stage-5 rollback source
for the Secret Manager migration.

Also update `NOETL_PASSWORD` inside `noetl-secret` to the new value if you want the
rollback path to stay usable — otherwise that Secret becomes stale and the stage-5
re-add would restore a dead password.

## 8. Close out

- Comment on noetl/ai-meta#310 and #304 with the rotation date.
- The exposed value is now worthless; git history can stay as it is.
- Consider a systematic secret scan of the public repos — this exposure was found
  incidentally, and no scan has been run.
