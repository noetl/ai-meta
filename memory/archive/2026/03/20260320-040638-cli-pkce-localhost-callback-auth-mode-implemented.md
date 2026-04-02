# CLI PKCE localhost callback auth mode implemented
- Timestamp: 2026-03-20T04:06:38Z
- Author: Kadyapam
- Tags: cli,auth0,pkce,gateway,docs,submodules

## Summary
Added a second gateway login mode in noetl/cli: --browser-pkce (alias --pkce) which starts a local localhost callback listener, performs Auth0 Authorization Code + PKCE exchange, and then exchanges resulting token with gateway /api/auth/login to cache a session token in context. Added --pkce-port and --auth0-redirect-uri overrides, retained optional client secret behavior, and documented the flow in noetl/docs and cli README. Updated ai-meta submodule pointers to repos/cli@b49e9cf and repos/docs@cb31ad8.

## Actions
- Implemented PKCE callback listener and code exchange in `repos/cli`.
- Added `--browser-pkce`/`--pkce`, `--pkce-port`, and `--auth0-redirect-uri` login flags.
- Updated CLI and docs references for browser PKCE workflow.
- Synced `ai-meta` pointers to latest merged submodule SHAs.

## Repos
- `repos/cli`
- `repos/docs`
- `ai-meta`

## Related
- noetl/cli commit `b49e9cf`
- noetl/docs commit `cb31ad8`
