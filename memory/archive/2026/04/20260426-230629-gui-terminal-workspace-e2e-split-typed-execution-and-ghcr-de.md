# GUI terminal workspace, e2e split, typed execution, and GHCR deploy flow
- Timestamp: 2026-04-26T23:06:29Z
- Author: Kadyapam
- Tags: gui,ops,e2e,noetl,docs,mcp,release,deploy

## Summary
April 2026 cross-repo work moved NoETL fixture ownership into noetl/e2e, added e2e docs/registration, updated ops deploy playbooks for GHCR image deployment, typed the execution observability API in noetl/noetl v2.23.2, and evolved noetl/gui into a terminal-first workspace with resizable terminal/dashboard panes, runtime env injection, validated GHCR image releases, and local kind deployment of ghcr.io/noetl/gui:v1.0.6. Docs now frame NoETL as a distributed business operating system and document terminal console commands. Next direction: deploy MCP servers, beginning with containers/kubernetes-mcp-server, and integrate the GUI terminal with available MCP-backed runtime observability.

## Actions
- Created dedicated `noetl/e2e` repository and moved end-to-end fixtures out of `repos/noetl/tests/fixtures`; credentials templates are commit-safe, while local JSON credential files remain uncommitted.
- Updated `repos/ops` fixture references and deployment automation so local/dev deploys can use published GHCR images instead of rebuilding images locally.
- Added docs in `repos/docs` for the terminal console workspace and expanded AI/meta docs with the distributed business operating system framing.
- Shipped typed execution observability in `repos/noetl`; `noetl.execution` is treated as a projection, with `noetl.command` and `noetl.event` remaining source-of-truth execution state tables.
- Refactored `repos/gui` to a terminal-first workspace: old Mac style UI, terminal/dashboard split, view toolbars, runtime env injection through `/env-config.js`, direct/gateway API modes, AI explanation rendering, resizable panes, maximization controls, and footer/header menu behavior.
- Released and deployed `noetl/gui` `v1.0.6` to local kind from `ghcr.io/noetl/gui:v1.0.6` using the ops GUI playbook with runtime env injection.
- Next planned direction is MCP runtime integration, beginning with `containers/kubernetes-mcp-server` for monitoring the Kubernetes runtime where NoETL is running.

## Repos
- `repos/e2e`: `501dcc0` (`Merge pull request #2 from noetl/kadyapam/e2e-docs-and-registration`)
- `repos/docs`: `88580e8` (`docs(gui): fix open command pipe rendering`)
- `repos/noetl`: `02961645` (`chore(release): version 2.23.2 [skip ci]`)
- `repos/ops`: `9be9f65` (`Merge pull request #9 from noetl/kadyapam/ghcr-image-deploy-playbooks`)
- `repos/gui`: `15aaaf2` (`fix(ui): release terminal workspace panes`), released as `v1.0.6`

## Related
- `noetl/e2e` PRs `#1`, `#2`
- `noetl/docs` PR `#11`
- `noetl/noetl` PR `#385`, release `v2.23.2`
- `noetl/ops` PR `#9`
- `noetl/gui` PRs `#7`, `#8`, `#9`, release `v1.0.6`
