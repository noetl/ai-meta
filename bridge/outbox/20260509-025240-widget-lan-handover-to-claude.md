# Handover to Claude — widget tutorial, LAN GUI access, and widget visibility UX

- Timestamp: 2026-05-09T02:52:40Z
- From: Codex
- To: Claude / Cowork
- Context: AI-OS widget renderer round 2 follow-through, docs/tutorial polish, local LAN GUI access

## Current outcome

The docs side is GREEN and deployed. `noetl/docs#44` landed the AI-OS docs text pass and `noetl/docs#45` added the tutorial `docs/tutorials/06-widget-rendering.md`. Cloudflare Pages deploy run `25584544097` completed successfully for docs#45. Public pages verified:

- https://noetl.dev/docs/gui/catalog-ux
- https://noetl.dev/docs/gui/widgets
- https://noetl.dev/docs/tutorials/widget-rendering/

The new tutorial explains how a playbook emits `result.render`, how to verify nested `render.args` using `noetl status --json`, how to view the widget through `report <execution_id>` in the terminal-style prompt, how `app:button` uses `event.key: command`, and how unsupported widget types fall back to a JSON preview.

## Local LAN access finding

The user opened the local GUI from another machine on the same network at `http://192.168.1.240:30081/`. The prompt showed `noetl@kind:/catalog$`, but `ls` returned `Network Error`.

Root cause was the GUI runtime config:

```js
VITE_API_BASE_URL: "http://localhost:8082"
```

From another machine, browser `localhost` points to that other machine, not to the Mac hosting Podman/kind. I patched the running local deployment:

```bash
kubectl -n noetl set env deploy/gui \
  VITE_API_BASE_URL=http://192.168.1.240:8082 \
  VITE_APP_VERSION=v1.8.0
kubectl -n noetl rollout status deploy/gui --timeout=120s
```

After rollout, `/env-config.js` showed:

```js
VITE_API_BASE_URL: "http://192.168.1.240:8082"
```

I also verified CORS from `Origin: http://192.168.1.240:30081` to `http://192.168.1.240:8082/api/executions` returned 200. This confirmed the `Network Error` was browser routing/config, not a noetl-server or catalog failure.

## How the user sees widgets

Current UX requires an explicit report command. Widgets do not automatically appear just because a playbook is running. The flow is:

1. Run a playbook that emits a step result with `render: { type, args }`.
2. Copy the parent `execution_id`.
3. In the GUI prompt, run:

```text
report <execution_id>
```

The textual report appears first, then the widget block renders beneath it. Before using the GUI, verify widget data exists with:

```bash
noetl --server http://192.168.1.240:8082 status <execution_id> --json \
  | jq '.. | objects | select(has("render")) | .render'
```

If `type` exists but `args.children` is missing, the stack is too old or event projection regressed. The intended local baseline is NoETL `v2.37.2+` and GUI `v1.8.0+`.

## Current live-state caveat

At the end of this handoff, Podman/kind became unreachable from the host:

```text
podman ps
Cannot connect to Podman ... dial tcp 127.0.0.1:51321: connect: connection refused

kubectl cluster-info
The connection to the server 127.0.0.1:52695 was refused
```

The previously verified LAN URLs (`http://192.168.1.240:30081/` and `http://192.168.1.240:8082/api/health`) also stopped responding after Podman disconnected. Next operator step is to restore the Podman machine, then re-check whether the GUI deployment still has the LAN IP runtime config. If the cluster is recreated or GUI redeployed, the `VITE_API_BASE_URL` patch may need to be reapplied or encoded into the local deployment playbook.

## Suggested next UX follow-up

The user asked, "playbook executing but how would I see widgets?" That indicates the current `report <execution_id>` discovery path is not obvious enough. Recommended follow-up:

- Add GUI prompt affordance after playbook execution completes: show/copy the parent `execution_id` and offer a clickable `report <execution_id>` command.
- Optionally render the latest execution report automatically when an execution finishes and contains a `render` descriptor.
- Ensure remote/LAN local deployments use a LAN-routable API base URL, not `localhost`, or teach the GUI to derive the API base from `window.location.hostname` when `VITE_API_BASE_URL` is `localhost` but the page is loaded from a non-localhost host.

## ai-meta state

ai-meta has local, unpushed commits for:

- docs pointer bump for widget tutorial
- docs text-pass result/handoff artifacts
- memory entries for docs/tutorial deployment and LAN access
- this handover

Do not assume ai-meta has been pushed unless the user says so.
