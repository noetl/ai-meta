# GUI LAN auto-rewrite + run auto-render widgets — GREEN
- Timestamp: 2026-05-09T03:46:56Z
- Author: codex
- Tags: gui,lan,widgets,auto-render,noetl-prompt,kind,podman,green

## Summary
Codex completed bridge task `20260509-030314-gui-lan-rewrite-and-run-auto-render`. GUI PR noetl/gui#27 shipped the LAN localhost auto-rewrite and prompt run auto-render watcher, released as `v1.9.0`. Validation found one prompt-run integration bug: the prompt resolved catalog playbooks but sent `version: "latest"` to `/api/execute`, which the v2 API rejects with HTTP 422 because catalog execution expects an integer version. Codex fixed it in noetl/gui#28 by carrying the resolved catalog version through the prompt run request; semantic-release cut `v1.9.1`. Local kind was recovered through the Podman LaunchAgent, and `deployment/gui` is now running `ghcr.io/noetl/gui:v1.9.1` with the helm/default-style `VITE_API_BASE_URL=http://localhost:8082` still in runtime env. LAN smoke from `http://192.168.1.240:30081/catalog` passed with no Network Error, proving the browser rewrites API calls to the LAN host at runtime. Widget smoke execution `622695138808038281` started from the prompt and auto-appended `tests/gui/widget_all_types :: completed (auto-rendered from execution 622695138808038281)` within about 4 seconds, rendering the full `Widget all-types coverage` tree without typing `report`. The app:button callback emitted `echo widget-button-command` into the prompt, preserving round-2 button behavior. Non-render probe `622695484049589148` completed with no spurious auto-render entry. Result file: `bridge/outbox/20260509-030314-gui-lan-rewrite-and-run-auto-render.result.json`.

## Follow-ups
- Flip the local helm/env default to `VITE_API_BASE_URL=""` in a future ops/chart round so the GUI derives from `window.location` without needing localhost rewrite compatibility.
- Add form-submit semantics for `app:form` / `app:customform` so widget values can seed a `run <playbook>` payload.
