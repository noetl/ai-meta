# muno bootstrap container build — GREEN

**Round:** 20260513-000000 (muno bootstrap + widget contract)
**Date:** 2026-05-13T00:26Z
**Agent:** Claude Code (Sonnet 4.6)
**Supersedes:** `memory/inbox/2026/05/20260513-002109-muno-bootstrap-container-build-amber.md`

## Summary

Round 20260513-000000 flips to GREEN. The single-line `package.json` fix
resolved the alpine bash/git blocker. Podman build completed successfully,
the nginx container served HTTP 200, and the ai-meta submodule pointer was
bumped locally.

## Fix applied

**Repo:** `noetl/muno`
**Branch:** `main` (direct commit, pre-CI repo)
**Commit:** `4143d4c` (full: `4143d4cXXX` — see git log in muno for full SHA)

| File | Change |
|------|--------|
| `package.json` | `"contracts"` script: `bash scripts/build_widget_contracts.sh` → `node scripts/generate_widget_contracts.mjs` |
| `scripts/build_widget_contracts.sh` | Deleted (was a one-node-invocation wrapper with pointless `git rev-parse` cd) |
| `package-lock.json` | Updated (npm install after deps were missing locally) |

Diagnosis confirmed: `node:20-alpine` has no `bash` or `git`. The wrapper script
existed only to `cd $(git rev-parse --show-toplevel)` then `node scripts/generate_widget_contracts.mjs`.
npm scripts already run from the package root, so the cd was a no-op. Both
`bash` and `git` are unnecessary once the wrapper is eliminated.

The `npm run type-check` on the host (Node v26) confirmed the direct invocation
works: `Generated src/contracts/widgets.ts from 24 schemas` — clean pass.

## Podman build result

| Item | Value |
|------|-------|
| Command | `podman build -t noetl-muno:bootstrap-smoke .` |
| Result | SUCCESS |
| Wall-clock time | ~76.5 s (including nginx:1.27-alpine pull on first run) |
| Image size | ~49.3 MB (51,717,823 bytes) |
| Image ID | `032d3c63fb16` |

Build stages both completed:
- Stage 1 (`node:20-alpine`): `npm ci` + `npm run build` (contracts generated, tsc clean, vite built)
- Stage 2 (`nginx:1.27-alpine`): dist copied, labels applied, port 8080 exposed

Vite reported `590.01 kB │ gzip: 181.92 kB` for the main JS bundle (chunk-size
warning noted — cosmetic, not a build failure).

## Run-test result

```
podman run --rm -d -p 18080:8080 --name muno-smoke noetl-muno:bootstrap-smoke
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/
```

**HTTP 200** — nginx SPA serving confirmed.

Container stopped and image removed (`podman rmi noetl-muno:bootstrap-smoke`).

## ai-meta submodule pointer

**Commit:** `9fde31b`
Message: `chore(sync): bump muno to 4143d4c — alpine bash/git fix unblocks container build`
Not pushed — Kadyapam pushes ai-meta on his schedule.

## Round verdict

**Round 20260513-000000 flips to GREEN.**
All muno bootstrap checks pass: 24 schemas, type-check, vite build, podman
container build, nginx HTTP 200 run-test.
