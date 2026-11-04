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

## ✅ Executed 2026-11-04 — complete

The first plan (server v3.151.1, worker v6.11.6) was **stopped by the pre-flight**.
Prod's embedded `d1_event_log` had an empty live active part beside a stale non-empty
one below the sealed range, and v0.14.10/11 would have resumed the stale one. The fix
was ehdb#437 → v0.14.12. What rolled:

| step | image | rollback | smoke after (e2e / travel / ranch) |
| :-- | :-- | :-- | :-- |
| server `sts/noetl-server-rust-embedded` 06:08Z | v3.151.2 `server-rust@sha256:166a8536cf235d2fb28becebd95486b98c1a0273707257dfdc2dde92eaa3e216` | `cd6ee866…` (v3.151.0) | 7/7 · PASS · PASS |
| user `deploy/noetl-worker-rust` 06:53Z | v6.11.7 `noetl-worker-rust@sha256:3f81edaf90c70cc961eaa666e0c1bbe9fae4a080d044976a86236deaba64f629` | `c78ae5725e589406e232aaca97e93c3290e4c3801d7d2dd4c1778992d35f4926` (v6.11.4) | 7/7 · PASS · PASS |
| `deploy/noetl-worker-system-pool` 07:01Z | v6.11.7 | `8d6b2c69981aeec12b9160639b5b121cf8b3fc87ae3c6385c2d86628c0506635` (v6.11.3) | 7/7 · PASS · PASS |
| `deploy/noetl-worker-system-pool-shard1` 07:15Z | v6.11.7 | `8d6b2c69…` (v6.11.3) | 7/7 · PASS · PASS |
| `sts/noetl-cmdbus-writer` 07:27Z | v6.11.7 | `3395fe0c065b66b91044ad0cd6b781515704d26fd70389895497446fc64cb19a` (v6.11.1) | 7/7 · PASS · 1 FAIL, then 5/5 PASS |

Lessons for the next run:
- **Patch named containers only.** `set image "*=…"` also replaces init containers, and
  the system pools' `wait-for-api` needs `curl`, which the worker image does not ship
  (this hit kind).
- `smoke.py` used to swallow poll errors; it now reports `last_poll_error`. The one
  writer-era ranch FAIL had COMPLETED on the server, so the read-back failed, not the turn.
- The writer's restart cost on prod is the election (lease 15 s, failover window 21 s),
  not recovery. Ready took 23 s.
- The e2e validator's DB-row checks read 0 on prod (it queries `noetl.event`; the event
  store is EHDB), so gate on 7/7 COMPLETED.

Test data left by the smoke: e2e catalog prefixes `prod-e2e-516-*`, and ranch threads
`_smoke-516-*` (delete from the ranch `/admin/` or with `shastaranch/chats/delete`).
