# Decision: The live `/api/dsl/*` upstream stays gated until a planned server roll

- **Date:** 2026-11-07
- **Status:** Accepted. Revisit at the next planned prod server roll.
- **RFC:** [`docs/rfc/dsl-knowledge-base.md`](../rfc/dsl-knowledge-base.md)

## Context

**What is done.** DSL-KB phases 1, 2 and 4 are merged: noetl/server#562 and #563, and
noetl/docs#197. noetl.ai serves the KB explorer, the release artifacts and MCP
(`noetl.dsl.describe`, `noetl.dsl.schema` and `noetl.dsl.validate`). Its live routes pass
through to `NOETL_DSL_UPSTREAM`, which is unset, so they answer `503 upstream_not_configured`.

**What turning it on involves.** Measured read-only on 2026-11-07:

- **Prod's version.** Prod runs server **v3.151.4** on `noetl-server-rust-embedded`, a
  single-replica StatefulSet with an embedded EHDB volume. `/api/dsl/*` returns 404 there,
  because the code is not in that version.
- **What a roll would carry.** It would not be a flag flip. It would be a version jump to a
  build of `main`, and that build also carries v3.152.0 and #561. #561 changes the gating in
  the off-server wasm drive, and prod runs off-server.
- **The runbook's costs.** The server-roll runbook (`playbooks/516-ehdb-426-rollout`) lists:
  - a **blocking pre-flight** exec on the volume, which last time needed the owner's go-ahead;
  - a ~35 min archive re-verify on restart;
  - a known reconcile-tick stall;
  - a travel + ranch smoke before and after.

  With one replica, the restart is a control-plane outage window.
- **Public reach.** It also needs a public route for the gateway (`gateway.mestumre.dev`), a
  second prod component.

## Decision

Leave it gated. Do not roll prod for this endpoint alone, and do not point noetl.ai at a non-prod
server. A dev upstream would report a grammar that is not the deployed one, which defeats
"version-accurate".

## What lighting it up needs (in order, one component at a time)

1. **Release a server version that contains #562 and #563**: `workflow_dispatch` `release.yml`
   with a version, or the next `feat`/`fix` release. Build the prod image into
   `shastaratech-noetl-prod` Artifact Registry. Pin the rollback digest. The current one is
   `server-rust@sha256:6cbf2fb29c659856462d772e4c8506885a52d6919777821e98d7d39c8616c4b5`
   (v3.151.4).
2. **Roll the server** per the 516 runbook:
   1. pre-flight the `*.active` files;
   2. run the travel + ranch smoke;
   3. patch the image by digest, and add the env `NOETL_DSL_KB=true`
      (`NOETL_CATALOG_PARSE_ON_REGISTER=shadow` is optional and records a would-reject baseline);
   4. watch the metrics;
   5. run the smoke again, and roll back on any regression.

   Ideally this rides a roll that was planned anyway.
3. **Gateway.** Add a public, read-only, rate-limited route `GET|POST /noetl/api/dsl/*` →
   server `/api/dsl/*`, with no credential forwarding. Roll the gateway separately, with its
   own smoke.
4. **noetl.ai.** Set `NOETL_DSL_UPSTREAM=https://gateway.mestumre.dev/noetl` on the Pages
   project `noetl-ai` (dashboard → Settings → Variables) and redeploy. Verify that
   `/api/dsl/version` is 200, that its `schema_digest` equals `/dsl/source.json`, and that the
   MCP `tools/call` succeeds.

## Consequences

- Until then, AIs use noetl.ai's release artifacts (`source.json` names the server commit),
  and `validate` is available only on servers that run phase 2 with the flag on, for example in
  kind.
- Nothing is armed in prod, and the rollback surface stays at zero.
