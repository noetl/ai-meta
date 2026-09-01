# Cloud SQL / pgbouncer — owner-run commands

**Nothing here has been applied.** These are instance and security settings;
the commands and impact assessment are below for the owner to run.

## Topology (verified live 2026-09-01)

```
noetl-server / workers
   -> pgbouncer.postgres.svc.cluster.local:5432   (edoburu/pgbouncer 1.24.1)
   -> 127.0.0.1:6432  cloud-sql-proxy 2.18.3      (sidecar, same pod)
   -> Cloud SQL  noetl-shared-pg  POSTGRES_15  db-custom-4-16384  us-central1
```

Instance: `ipv4Enabled: false`, private network only, no authorized networks.

---

## 1. SSL mode → `ENCRYPTED_ONLY` — **verdict: SAFE**

Current: `sslMode: ALLOW_UNENCRYPTED_AND_ENCRYPTED`, `requireSsl: false`.

**Why it is safe here.** The only path to the instance is the **Cloud SQL Auth
Proxy**, which *always* establishes a TLS connection regardless of the
instance's `sslMode` — that is not configurable and cannot be turned off. The
instance additionally has **no public IP** and **no authorized networks**, so
there is no other client. Flipping the flag removes an option nothing is using.

```bash
gcloud sql instances patch noetl-shared-pg \
  --project=shastaratech-noetl-prod \
  --account=shastaratech@gmail.com \
  --ssl-mode=ENCRYPTED_ONLY
```

Verify:
```bash
gcloud sql instances describe noetl-shared-pg --project=shastaratech-noetl-prod \
  --format='value(settings.ipConfiguration.sslMode)'   # expect ENCRYPTED_ONLY
kubectl -n noetl exec deploy/noetl-server-rust -- \
  wget -qO- http://127.0.0.1:8082/api/health           # expect database:connected
```

⚠ `gcloud sql instances patch` may briefly restart connections. Do it in a
quiet window; the server reconnects on its own.

**Rollback:** `--ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED`.

---

## 2. pgbouncer pool caps 12→25 / 16→32 — **verdict: SAFE, and justified**

Current (env on both sidecars): `DEFAULT_POOL_SIZE=12`, `MAX_DB_CONNECTIONS=16`,
`MAX_CLIENT_CONN=600`, `POOL_MODE=transaction`, pgbouncer `replicas: 1`.

**Why it is the real constraint.** `MAX_DB_CONNECTIONS=16` caps *server-side*
connections per database. KEDA scales `noetl-worker-rust` to **20 replicas**
under backlog — observed doing exactly that during load testing — plus the
server and both system pools. Demand exceeds 16, so clients queue inside
pgbouncer. That is what surfaces as "connections impacting performance": not
saturation at Postgres, but a bottleneck in front of it.

**Headroom check.** Cloud SQL `max_connections` is unset, so the tier default
applies (~400 for 16 GB). pgbouncer is a **single replica**, so the new ceiling
is 32 server connections, not 32×N. 32/400 ≈ 8% — ample margin.

These are env vars on the Deployment, so this is a rolling restart, not an
instance change:

```bash
kubectl -n postgres set env deploy/pgbouncer \
  DEFAULT_POOL_SIZE=25 MAX_DB_CONNECTIONS=32
kubectl -n postgres rollout status deploy/pgbouncer --timeout=180s
```

⚠ `set env` applies to **all** containers in the pod unless `-c` is given, and
both sidecars carry these names. That is what you want here (they should
agree), but it is worth knowing it touches both.

Verify:
```bash
kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  psql -h 127.0.0.1 -p 5432 -U pgbouncer pgbouncer -c 'SHOW CONFIG;' \
  | grep -E 'default_pool_size|max_db_connections'
```

**Rollback:** `set env ... DEFAULT_POOL_SIZE=12 MAX_DB_CONNECTIONS=16`.

---

## 3. Duplicate database entries — **verdict: a real defect, fix deliberately**

`DATABASE_URLS` currently contains **four** entries over **two** distinct
database names:

```
postgres://noetl:noetl@127.0.0.1:6432/noetl
postgres://demo:demo@127.0.0.1:6432/demo_noetl
postgres://auth:auth@127.0.0.1:6432/demo_noetl     <- demo_noetl again
postgres://postgres:demo@127.0.0.1:6432/noetl      <- noetl again
```

The entrypoint renders these into pgbouncer's `[databases]` section, where the
key is the database name and **duplicate keys mean last-one-wins**. So today:

- `noetl` is served as user **`postgres`**, not `noetl`
- `demo_noetl` is served as user **`auth`**, not `demo`

The first and second entries are silently discarded. This is not currently
*breaking* anything — connections succeed, because the surviving credentials are
valid — but the effective identity is not the configured one, which means
per-user grants and audit attribution are not what the config appears to say.

⚠ **Do not "fix" this by simply deleting the duplicates without checking which
identity is actually in use.** The live behaviour is the *last* entry; removing
it would change the connecting user and could break grants. The safe sequence:

1. Confirm what is actually connecting:
   ```bash
   kubectl -n postgres exec deploy/pgbouncer -c pgbouncer -- \
     psql -h 127.0.0.1 -p 5432 -U pgbouncer pgbouncer -c 'SHOW DATABASES;'
   ```
2. Decide the intended identity per database (this is the owner's call — it is
   a grants question, not a config-syntax one).
3. Rewrite `DATABASE_URLS` with **one entry per database name**, then roll.

Because step 2 is a decision rather than a mechanical fix, no command is
pre-written here. Flagging the defect and the hazard is the deliverable.

---

## Not included

IAM, secrets and credential rotation remain deferred per the owner's standing
instruction until dev + testing are complete.
