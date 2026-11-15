# Quantum readiness (shastaranch, private): qnetmon#45 deployed with switches OFF
- Timestamp: 2026-11-15T18:45:00Z
- Author: Kadyapam
- Tags: quantum-readiness, shastaranch, qnetmon, control-plane, deploy, flag-gated

## Summary

The owner authorized deploying finished, waiting work. qnetmon#45 (hosted Worker port of SPEC 4.1 enrollment tokens, 4.2 operator-assigned cohort and 8 instance discovery) is now live with both switches **off**. Live equals qnetmon main (`91db720`).

## Actions

- `wrangler deploy` at 2026-11-15 18:38 UTC: qnetmon-web version `a668c5de-a6ce-43e5-9c38-4428eb2ad8b0` at 100%. The deploy message references #45.
- Rollback pin: `npx wrangler rollback d5e83815-7202-4858-b994-dd9c8a11c240` (the #43 version).
- Live checks passed: health 200, operator routes 401 without the token, discover 404 "discovery not enabled", unsigned report 400, `/quantum/` and `/` redirect to the login page (200).
- Docs: shastaranch/noetl-quantum-readiness#69.

## Still the owner's

- Turning on `QREADY_ENROLL` / `QREADY_DISCOVER` on the hosted plane.
- The binary-upgrade mode, offline-root custody, the first Comware bulletins, Podman under systemd at Shasta Ranch.
