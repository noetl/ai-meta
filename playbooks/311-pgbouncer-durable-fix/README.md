# #311 — the durable pgbouncer fix: source the userlist from Secret Manager

**Status:** kind-proven, **not applied to prod**. One prerequisite is owner-only
(an IAM grant, §2).

## The problem this ends

The 2026-08-28 rotation was finished with a **SIGHUP reload** of pgbouncer's
`userlist.txt` — correctly, because it avoided dropping the pool. But the reload
is ephemeral: the edoburu entrypoint regenerates `userlist.txt` from
`DATABASE_URLS` on every container start, and `DATABASE_URLS` is an inline
literal in the Deployment spec still holding the pre-rotation password.

On **2026-08-29T04:53:24Z** GKE Autopilot's `optimize-utilization-scheduler`
rescheduled the pod. The new container regenerated the stale userlist and the
whole platform lost database auth. **This recurs on every reschedule** until the
userlist stops coming from that literal.

## The fix, and why it needs no credential handling

A wrapper builds the userlist from a Secret Manager **CSI mount** before handing
off to the image's own entrypoint. The value goes file → file; it is never
echoed, never in argv, never read by a human or an agent.

The load-bearing detail is in the image itself:
`generate_userlist_if_needed` only appends a user that is **not already in the
auth file**. So a pre-populated `noetl` entry is never overwritten — and
`DATABASE_URLS` **does not need to be edited at all**. The stale password in it
simply stops being consulted.

That is what makes this deployable without touching a value.

## 1. Kind evidence

Run against `edoburu/pgbouncer:v1.24.1-p1` in the kind cluster, fronting a real
Postgres:

| arm | result |
| :-- | :-- |
| A — userlist built from the mount | one entry, from the mounted file |
| B — `[databases]` section | routing only, `auth_user=noetl`, **no password** |
| C — client auth through pgbouncer | `AUTH_OK` |
| **D — pod deleted, new pod** | **identical userlist md5 `54316ddf7541`, `AUTH_OK`** — the property that failed in prod |
| **E — positive control**: wrong value on the mount | `FATAL: SASL authentication failed` — so the userlist genuinely comes from the mount |
| F — restore the mount | `AUTH_OK` again, with **no manual userlist edit** |
| **G — the prod scenario**: stale wrong password in `DATABASE_URLS`, correct one on the mount | **`AUTH_OK`** — the mount wins over the stale literal |
| H — restart in that same configuration | `AUTH_OK_AFTER_RESTART` |

E is what makes D and G non-vacuous: the check can fail, and does.

## 2. ⚠ Prerequisite — an IAM grant, owner-only

pgbouncer runs as ServiceAccount `cloudsql-proxy`, whose Workload Identity GSA
`noetl-cloudsql-proxy@shastaratech-noetl-prod.iam.gserviceaccount.com` currently
holds **only `roles/cloudsql.client`**. Without Secret Manager access the CSI
mount fails and pgbouncer will not start — which would take prod from *down* to
*down and un-recoverable by the reload*. **Do not apply §3 before this
succeeds.**

```bash
gcloud secrets add-iam-policy-binding noetl-postgres-password \
  --member="serviceAccount:noetl-cloudsql-proxy@shastaratech-noetl-prod.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor" \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
```

Verify (the role is `secretAccessor` — a substring match on "accessor" gives a
false negative):

```bash
gcloud secrets get-iam-policy noetl-postgres-password \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com \
  --format="table(bindings.role, bindings.members)"
```

## 3. Apply

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$CTX" apply -f secretproviderclass.yaml
kubectl --context "$CTX" -n postgres patch deploy pgbouncer \
  --patch-file pgbouncer-patch.yaml
kubectl --context "$CTX" -n postgres rollout status deploy/pgbouncer --timeout=5m
```

⚠ Apply the two files **individually as shown**. Do not `kubectl apply -f` the
directory — that is the hazard [#309](https://github.com/noetl/ai-meta/issues/309)
is about.

## 4. Verify

```bash
# the userlist came from the mount (masked — never print the value)
kubectl --context "$CTX" -n postgres exec deploy/pgbouncer -c pgbouncer -- \
  awk '{printf "%s %s…(%d chars)\n", $1, substr($2,1,3), length($2)-2}' /etc/pgbouncer/userlist.txt

# the platform heals on its own
kubectl --context "$CTX" -n noetl get pods -w
```

Expect the crashlooping `noetl-server-rust`, `noetl-worker-rust` and
`noetl-cmdbus-writer-0` to go Ready without further action, then an e2e run.

## 5. Rollback — read this before applying

```bash
kubectl --context "$CTX" -n postgres rollout undo deploy/pgbouncer
```

⚠ **Rolling back restores the broken stale-password config.** It is not a safe
resting state — it is the state that caused the outage. If this fix fails, the
fallback is the owner's userlist reload
(`playbooks/secret-manager/RECOVER-ROTATION-MISMATCH.md`), not the rollback.

## 6. Two findings this surfaced

- **The live pgbouncer Deployment is undeclared in IaC.** `repos/ops` has no
  pgbouncer manifest at all (`ci/manifests/postgres/` covers Postgres only), so
  prod's pooler exists only in the cluster. Same class as
  [#267](https://github.com/noetl/ai-meta/issues/267).
- **The CSI driver name is `secrets-store-gke.csi.k8s.io`**, the GKE add-on, not
  the upstream `secrets-store.csi.k8s.io`. Read off the live server pod; the
  upstream name would have failed the mount.
