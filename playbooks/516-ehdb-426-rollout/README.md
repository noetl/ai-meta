# #516 — roll the ehdb#426 hardening to prod

Tracks [noetl/ai-meta#516](https://github.com/noetl/ai-meta/issues/516) /
[noetl/ehdb#426](https://github.com/noetl/ehdb/issues/426).

## What ships where

| Consumer | Carries the fixes via | Gate |
| :-- | :-- | :-- |
| `noetl-server-rust-embedded` (STS, 1 replica) | server **v3.151.1** (noetl/server#553, ehdb v0.14.10) — AR `server-rust@sha256:0db699bb5b500201dcc05c065f45a22e149c536e5a6a58a59830a3ebe2e739c6` | mine — this runbook |
| worker pools (user, system ×2) | worker **v6.11.6** (noetl/worker#393, ehdb v0.14.11) — `noetl-worker-rust:6.11.6` = `sha256:8b70e59a6f231481b8f1cca0fcd7e0548392c31616d0006abcfc7ee5303d1b4b` (⚠ AR worker tags have **no** `v`) | mine — after the server, one pool at a time |
| `noetl-cmdbus-writer` (hosts both bus L0 engines) | the same worker image | ⛔ **owner-gated** — restart hazard, see #460 |

## Pinned rollback (read off the running pod 2026-11-04)

```
SERVER_ROLLBACK=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:cd6ee86646e1155a8550e83febe8fa9b818d942a3c3466838ed0f0363f2b2999   # v3.151.0
```

## Pre-flight (read-only) — ⚠ BLOCKING

With ehdb v0.14.10, **bit-rot in ANY `*.active` file fails the server's open**
(it used to read only `part-000000.active`). List and check every active part on
the volume before rolling:

```bash
kubectl --context noetl-prod -n noetl exec noetl-server-rust-embedded-0 -c noetl-server -- \
  sh -c 'find /data -name "*.active" -exec ls -l {} \;'
```

A torn tail is fine (it is recovered). A file whose frames fail the magic/CRC
check blocks startup; quarantine it (move, never delete) before rolling.

⚠ This exec was **denied by the session's permission policy** on 2026-11-04 — it
needs the owner's go-ahead or the owner runs it.

## Roll

1. Smoke **before** (see *Smoke* below), record results. ⚠ The first pre-roll run
   is also `smoke.py`'s first live run: it must PASS before it can be trusted as
   a gate.
2. `kubectl --context noetl-prod -n noetl get sts noetl-server-rust-embedded -o yaml`
   and save it. Patch **only the image by digest** — never apply the manifest
   ([`apply-safety.md`](../../agents/rules/apply-safety.md)).
3. Watch: pod Ready, `noetl_server_build_info{version}` = the new tag,
   `ehdb_l0_seal_failed` present at 0 (proves the new ehdb is running),
   `ehdb_l0_recovered_active_records` (expected > 0 on a restart),
   no `open_failed` on `noetl_ehdb_embedded_shadow_total`.
4. Smoke **after**. Regression ⇒ patch back to `SERVER_ROLLBACK`.

Expect the documented restart costs: ~35 min archive re-verify if Q5 is not `on`
(it was turned `on` midday 2026-11-03 — read the env off the pod before rolling,
do not trust this line), and the reconcile-tick stall pattern
([[reconcile-tick-chain-walk-stall]]).

## Smoke (agreed with the owner 2026-11-04)

Before AND after **each** roll (server, then each pool separately). **Any
regression in travel OR ranch ⇒ roll back.**

```bash
kubectl --context noetl-prod -n noetl port-forward pod/noetl-server-rust-embedded-0 28182:8082 &
# 1. e2e fixtures (credential-free)
repos/e2e/scripts/prod_regression_validate.py --base http://127.0.0.1:28182 \
    --prefix prod-e2e-516-$(date +%Y%m%d-%H%M) --set smoke --no-metrics
# 2. travel planner turn + 3. ranch concierge turn (live gateway, guest session)
python3 -I playbooks/516-ehdb-426-rollout/smoke.py <pre-server|post-server|pre-user|...> \
    --server http://127.0.0.1:28182 --out "$SCRATCH"
```

- `smoke.py` refuses if `noetl_server_build_info` is absent at `--server`, and
  prints it — confirm it says the PROD version (port-forward fails open).
- ranch = `POST {gateway}/api/auth/guest` → GraphQL `executePlaybook(
  "shastaranch/concierge/turn")` on a `_smoke-516-*` thread → poll
  `/noetl/executions/<id>` until a reply (`messages` of widget envelopes). Same
  path the mountshastaranch.com chat uses (`site/src/chat/gateway.rs`).
- Smoke threads/chats are test data: delete from the ranch `/admin/` (Delete
  data) or `shastaranch/chats/delete` afterwards.
- After a **system-pool** roll, wait out the ~7–10 min `WAL chain incomplete`
  window before the post smoke; a FAIL inside it is that, not the release.

## Open questions for the owner

- ~~What is the "ranch" smoke?~~ Answered 2026-11-04 — see *Smoke*.
- Go-ahead for the pre-flight exec above. **(pending — roll on HOLD)**
- Go-ahead (or not) for the cmdbus-writer. **(pending — roll on HOLD)**

## Order once unblocked

1. Pre-flight (read-only) → server v3.151.1 by digest (rollback `cd6ee866…`).
2. Worker v6.11.6: user pool → smoke → system pool A → wait 7–10 min → smoke →
   system pool B → wait → smoke. Never both system pools together. Record each
   pool's current digest as its rollback before patching.
3. cmdbus-writer only if the owner says so.

## Kind validation (done 2026-11-04)

Embedded mode on a PVC, prod EHDB flags minus GCS. e2e `core`: v3.147.0 baseline
30/66 green (×2, same set) vs v0.14.10 **30/66, identical set**; restart recovered
202 active-part records, `seal_failed` 0. ⚠ `tests/storage_tiers_test` OOM-kills
the 768 MiB kind worker on either image and stalls the queue behind it.
