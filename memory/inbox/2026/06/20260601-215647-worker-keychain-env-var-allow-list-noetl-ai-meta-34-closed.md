# Worker keychain env-var allow-list — noetl/ai-meta#34 closed
- Timestamp: 2026-06-01T21:56:47Z
- Author: Kadyapam
- Tags: phase-c2,keychain,credentials,worker,boundary-discipline,closed

## Summary
Closed noetl/ai-meta#34 (worker ExecutionContext.secrets unpopulated
from envFrom Secrets) — the boundary-discipline gap surfaced by the
Phase C2 kind validation.

## What landed

noetl/worker#35 — `CommandExecutor` lifts env vars listed in
`NOETL_KEYCHAIN_ENV_VARS` into a per-executor keychain map at
startup; each command's `ExecutionContext.secrets` gets seeded from
that map before tool dispatch.  Shipped in noetl-worker 5.7.0.

noetl/ops#134 — drops the sed-injection workaround from the
validation rig (the noetl/ops#133 block).  generate-flight-tls.sh
now sets `NOETL_KEYCHAIN_ENV_VARS=NOETL_FLIGHT_BEARER_TOKEN` on the
worker deployment patch alongside the existing envFrom.
validate-flight-tls.sh registers the playbook YAML verbatim.

noetl-worker-wiki@378f461 — new `worker-credentials` page
documenting the convention + design choice (allow-list vs
prefix-strip) + production deployment shape.

## Convention

Operator deployment:

  envFrom:
    - secretRef:
        name: noetl-worker-credentials   # carries NOETL_FLIGHT_BEARER_TOKEN, ...
  env:
    - name: NOETL_KEYCHAIN_ENV_VARS
      value: NOETL_FLIGHT_BEARER_TOKEN,DUFFEL_API_KEY

Playbook:

  tool:
    kind: result_fetch
    bearer_token: NOETL_FLIGHT_BEARER_TOKEN   # alias = env var name

At worker startup: read allow-list, lift each named env var into
`keychain_env: HashMap<String,String>`.  At each command dispatch:
seed `ctx.secrets` from `keychain_env`.  Tools call
`ctx.get_secret("NOETL_FLIGHT_BEARER_TOKEN")` and get the value.

## Why allow-list (not prefix-strip)

- Env-var name MATCHES the natural alias — operator names the
  Secret key once; alias in playbook matches without transformation.
- Operator-controlled scope — only listed vars become secrets;
  everything else (PATH, HOSTNAME, NATS_URL, etc.) stays out.  No
  accidental dumping.
- Empty / unset allow-list ⇒ pre-#35 deployments keep working
  unchanged.

## Defensive shapes pinned by tests

- Unset allow-list → empty map (no-op default).
- Mid-rollout: allow-listed but env var not yet set ⇒ silent skip
  (no startup spam).
- Blank string values rejected (would otherwise auth as empty
  token, worse than failing closed).
- Whitespace + trailing commas in allow-list tolerated.

## Boundary discipline win

Pre-#35: the validation rig wrote the literal bearer token into a
tmpfile the kind catalog ingested.  The token never landed in the
repo but DID travel through the rig artifacts + catalog DB.

Post-#35: the literal stays in the worker's env + in-process
secrets map.  The catalog, the registered playbook, and the rig's
artifacts only carry the alias — same shape as a production
deployment with cert-manager-issued Secrets.

## Pointer-bump trail (ai-meta main)

- 4094aa0 — bump worker to ceec37e (5.7.0 with keychain loader)
- a20591c — bump noetl-worker-wiki to 378f461 (worker-credentials page)
- 68ac848 — bump ops to 5fdcbec (rig drops sed workaround)

## What's pending

- Manual kind re-validation: worker image rebuild in progress
  (cargo-chef build cycle), then `validate-flight-tls.sh` should
  pass the same SQL probes WITHOUT the sed step in the rig's
  output.

## Open ai-task issues after this closure

- #30 — Appendix H umbrella (broader Rust migration, in progress)
- #31 — R-3 follow-up: CLI GCS sink to object_store crate (unrelated)

Phase C2 trust-boundary work + its closure follow-ups are fully
landed.

## Actions
-

## Repos
-

## Related
-
