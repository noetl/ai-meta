# Quantum readiness (shastaranch, private): qnetmon#43 deployed, hosted promotion proven locally, Worker port of enroll/cohort/discover
- Timestamp: 2026-11-15T08:00:00Z
- Author: Kadyapam
- Tags: quantum-readiness, shastaranch, qnetmon, control-plane, deploy, flag-gated

## Summary

The owner authorized merging and deploying qnetmon#43, the only finished item that was waiting. It is merged and live. Hosted canary→stable promotion was proven on the deployed code locally, because the live plane has no sites. The remaining hosted-Worker TARGETs (enrollment, cohort, discovery) were ported, merged and switched off by default. They are **not deployed**.

## Actions

- **qnetmon#43** merged `1c16e5d`. Deployed with `wrangler deploy` at 2026-11-15 07:47 UTC: version `d5e83815-7202-4858-b994-dd9c8a11c240`. Rollback: `wrangler rollback 25ba7855-39fc-4250-ad29-583b75a09dfa`.
  - Live checks: health 200, `/v1/sites` 401 without a token, `/quantum/` 302 to `/login`, `/login` 200.
  - The live hosted D1 has 0 sites and 0 reports.
- **qnetmon#44** merged `98fa2f0`: `hosted-promote.e2e.sh`, run under `wrangler dev --local`. It covers fleet parity fields, hold → promote → blocked → revoke → promote, a `--publish` the stable site applies, and `/quantum/` 200 behind the gate. ALL PASS.
- **qnetmon#45** merged `91db720`, not deployed: SPEC 4.1, 4.2 and 8 on the Worker. Enrollment and discovery are switched by the vars `QREADY_ENROLL` / `QREADY_DISCOVER`, both off. `npm test` 15 pass; e2e F1–F5 pass. An independent review fix is included: a token-spend race in the enrollSite batch.
- **noetl-quantum-readiness#67** (merged `b1620ba`) and **#68**: status docs.

## Lessons

- **A D1 batch is atomic but cannot branch.** When a later statement depends on an earlier one having succeeded, gate it with `changes() = 1` and repeat the full predicate. Matching on the values the first statement wrote is not enough, because timestamps collide.
- **"Verify on live" can be empty.** With 0 enrolled sites, the honest proof is the deployed commit under `wrangler dev --local`. Don't seed test sites into production D1 to make a live check look complete.
- **Apply every D1's migrations locally**, the demo DB included, before testing gated pages under `wrangler dev`. Otherwise `/login` answers 500 and the failure looks like a Worker bug.

## Open / needs the owner

- Deploy qnetmon#45. qnetmon main is now ahead of live, so the next deploy ships it with both switches off.
- Whether to turn on hosted enrollment or discovery.
- The D-21 `binary_upgrade` mode for Shasta Ranch.
- Offline-root custody and expiry cadence.
- The first Comware bulletins.
- Podman under systemd at Shasta Ranch.
- Still TARGET:
  - cluster-runtime ports, because kind-noetl is shared with another session;
  - ASA / NX-OS / Junos adapters, because there are no captures.
