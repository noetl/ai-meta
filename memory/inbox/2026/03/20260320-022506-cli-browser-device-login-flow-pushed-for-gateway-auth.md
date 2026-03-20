# CLI browser/device login flow pushed for gateway auth
- Timestamp: 2026-03-20T02:25:06Z
- Author: Kadyapam
- Tags: cli,auth0,gateway,device-flow,docs,submodules

## Summary
Implemented and pushed noetl/cli browser-based Auth0 device authorization flow to emulate gcloud-style login without requiring manual token capture from browser URL fragments. Password flow now accepts optional client secret (via flag/env/context) to avoid mandatory local secret storage, and context supports optional Auth0 audience. noetl/docs already documents browser login and secretless auth flow. ai-meta submodule pointers are being bumped to repos/cli@3ef88b3 and repos/docs@0f36e3a for reproducible sync.

## Actions
- Rebasing local CLI auth changes on top of `origin/main` (`v2.9.0`) and pushing to `noetl/cli`.
- Validating build with `cargo fmt --check` and `cargo check`.
- Preparing `ai-meta` submodule pointer updates for `repos/cli` and `repos/docs`.

## Repos
- `repos/cli`
- `repos/docs`
- `ai-meta`

## Related
- noetl/cli commit `3ef88b3`
- noetl/docs commit `0f36e3a`
