# muno bootstrap container build — AMBER (bash missing in alpine)

**Round:** 20260513-000000 (muno bootstrap + widget contract)
**Date:** 2026-05-13T00:21Z
**Agent:** Claude Code (Sonnet 4.6) — local verification pass

## Summary

Podman container build for `noetl/muno` was attempted locally (prior Codex run
deferred because the cloud sandbox couldn't reach the podman socket). The build
**failed** at the `npm run build` step. Round 20260513-000000 remains **AMBER**.

## Environment

| Item | Value |
|------|-------|
| podman version | 5.8.2 |
| machine name | noetl-dev (applehv) |
| machine state at start | stopped (last up ~8 min prior) |
| action taken | `podman machine start noetl-dev` |
| machine state after start | running |
| podman info arch/os | arm64 / linux |
| muno commit | ec43adeadf7aa0514a2479f21da8fb2a481769e7 |

## Build attempt

```
cd /Volumes/X10/projects/noetl/ai-meta/repos/muno
podman build -t noetl-muno:bootstrap-smoke .
```

**Wall-clock time:** ~25 seconds (failed in builder stage)

**Result:** FAIL — exit code 127

## Failure detail

The build failed at `[1/2] STEP 6/6: RUN npm run build` inside the
`node:20-alpine` builder stage. The `build` npm script is:

```
"build": "npm run contracts && tsc --noEmit && vite build"
```

which first calls:

```
"contracts": "bash scripts/build_widget_contracts.sh"
```

`node:20-alpine` ships only `sh`/`ash` — **`bash` is not installed**. The
script `scripts/build_widget_contracts.sh` uses `#!/usr/bin/env bash` and is
invoked explicitly via `bash`. Alpine's shell resolves neither.

Exact error from podman:
```
sh: bash: not found
Error: building at STEP "RUN npm run build": while running runtime: exit status 127
```

No image was created; `podman images | grep noetl-muno` returned empty.
No cleanup needed.

## Secondary observation

`scripts/build_widget_contracts.sh` also calls `git rev-parse --show-toplevel`
on line 3. There is no `.dockerignore` in the muno repo, so `.git` is copied
into the build context — meaning `git` would need to be available in the alpine
image too (it is not by default). This would be the second failure if bash were
added alone. Both issues are in the contracts script, not the Dockerfile shape.

## Fix options (for muno maintainer — not applied here, verification-only round)

**Option A (simplest):** Change the `contracts` npm script to use `sh` instead
of `bash` and convert `build_widget_contracts.sh` to POSIX sh:
- Remove `set -euo pipefail` (use `set -eu`; `pipefail` is bash-specific)
- Replace `bash scripts/build_widget_contracts.sh` with `sh scripts/build_widget_contracts.sh`

**Option B:** Add `RUN apk add --no-cache bash git` before the `npm ci` step in
the Dockerfile builder stage. Bash + git are both needed.

**Option C:** Inline the contracts generation directly in `generate_widget_contracts.mjs`
and invoke it as `node scripts/generate_widget_contracts.mjs` (skipping the shell
wrapper entirely). This is cleanest for a container build.

Option A or C are preferred to keep the alpine image minimal.

## What passed in round 20260513-000000

- 24 JSON widget-contract schemas validated
- npm install succeeded
- tsc type-check passed (host, not container)
- vite build passed (host, not container)
- widget-renderer dispatch smoke passed (host)
- Dockerfile and nginx.conf shapes are correct (mirror gui/ known-good pattern)
- nginx.conf: listens on 8080, SPA fallback to index.html, correct static asset log suppression

## Round status

**Round 20260513-000000 remains AMBER.**
Blocker: `bash` (and `git`) not present in `node:20-alpine` builder stage.
One-line fix is available; needs a muno code commit to apply.
