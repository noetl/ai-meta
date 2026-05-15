# GUI quiet nginx + frontend login-related logs
- Timestamp: 2026-04-28T14:15:11Z
- Author: Kadyapam
- Tags: gui,logging,nginx,observability,login

## Summary
`repos/gui` was emitting a flood of login-related stdout traffic from two sources: (1) the SPA's nginx pod logged every `/env-config.js`, static-asset, and SPA-bootstrap request — `/env-config.js` is fetched on every page load with no-cache headers, so the login-redirect dance and any session-expiry SPA reload turned the pod log into noise; (2) the frontend's Axios response interceptor logged the full Axios error object on every 401, and during normal session expiry the SPA fires several parallel polls that all return 401 simultaneously, producing a stack of duplicate console errors. Landed a topic branch `kadyapam/quiet-nginx-and-frontend-logs` (`79063db fix(gui): quiet nginx and frontend login-related logs`) on `repos/gui` that silences both without losing the signals that matter.

## Actions
- `nginx.conf`: added a `$loggable_request` map that skips `access_log` for static asset extensions; turned `access_log off` for `/env-config.js`, `/favicon.ico`, and `/robots.txt`. SPA HTML routes and API-shaped paths still log via the default `access_log`. `error_log` left at default level so genuine failures still surface.
- `src/services/api.ts`: changed the response interceptor to silently clear local session storage on 401 (no console output) and reduced other failures to a single one-line `console.warn` `API METHOD URL → STATUS: message` instead of dumping the full Axios error object.
- `src/components/Execution.tsx`: removed the leftover `console.log("🔍 PARSING PLAYBOOK CONTENT")` debug line that fired on every execution detail render.

## Repos
- `repos/gui`: branch `kadyapam/quiet-nginx-and-frontend-logs` at `79063db` (3 files, +39/−4). Local-only — push to `noetl/gui` then bump ai-meta gitlink after upstream merge.

## Open follow-ups
- Push `repos/gui` topic branch upstream, open PR, after merge bump the ai-meta `repos/gui` gitlink.
- Consider extending the same pattern to other GUI-side noisy paths if the operations team flags them; the `$loggable_request` map is the place to add new exemptions.
- Optional: gate `console.warn` in `api.ts` behind `import.meta.env.DEV` if the warn log level itself becomes too chatty in production browsers.

## Related
- Sandbox cannot reach `git@github.com:22` or `https://github.com/...` (proxy `403 from CONNECT`), so `git pull --rebase && git push` for ai-meta + `repos/gui` topic branch must run from the user's Mac.
