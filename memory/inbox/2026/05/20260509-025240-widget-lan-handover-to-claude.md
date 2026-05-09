# Widget LAN access + visibility handover to Claude
- Timestamp: 2026-05-09T02:52:40Z
- Author: codex
- Tags: ai-os,widgets,gui,lan-access,handover,claude,podman

## Summary
Created Claude handover at `bridge/outbox/20260509-025240-widget-lan-handover-to-claude.md`. It captures: docs#44/#45 are deployed to Cloudflare Pages; the new widget tutorial is live at `https://noetl.dev/docs/tutorials/widget-rendering/`; local same-network GUI access initially failed with `Network Error` because runtime config pointed to `VITE_API_BASE_URL=http://localhost:8082`; the running GUI deployment was patched to `http://192.168.1.240:8082` and CORS was verified; widgets currently appear by running `report <execution_id>` in the GUI prompt after a playbook emits `result.render`.

## Current caveat
After the LAN fix was verified, Podman/kind became unreachable from the host: `podman ps` failed with `dial tcp 127.0.0.1:51321: connect: connection refused`, and `kubectl cluster-info` failed against `127.0.0.1:52695`. The previously verified LAN URLs stopped responding once Podman disconnected. Next operator action is to restore the Podman machine, then re-check `/env-config.js` on `http://192.168.1.240:30081/env-config.js`. If the GUI was redeployed or the cluster recreated, reapply or encode the LAN-routable `VITE_API_BASE_URL` setting.

## Suggested follow-up
The user asked how to see widgets while a playbook is executing. The current implementation requires `report <execution_id>`; it does not auto-render widgets immediately on playbook start/completion. Recommended UX follow-up: after execution creation/completion, show the parent execution id and a clickable `report <execution_id>` command; optionally auto-open the latest report when the execution contains `result.render`.

## Repos
- ai-meta local handover file: `bridge/outbox/20260509-025240-widget-lan-handover-to-claude.md`
- docs live tutorial: `https://noetl.dev/docs/tutorials/widget-rendering/`

## Related
- docs#45: https://github.com/noetl/docs/pull/45
- Memory earlier in this thread: `memory/inbox/2026/05/20260509-012626-docs-widget-tutorial-and-local-lan-access.md`
