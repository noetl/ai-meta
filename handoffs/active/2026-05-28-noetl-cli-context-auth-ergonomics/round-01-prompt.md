---
thread: 2026-05-28-noetl-cli-context-auth-ergonomics
round: 1
from: claude
to: codex
created: 2026-05-28T01:40:00Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "proceed with noetl cli release"
---

# Round 01 — noetl CLI context + auth ergonomics

> **Predecessor:** none — fresh thread.  The broader infrastructure
> work that surfaced these CLI friction points is archived at
> `handoffs/archive/2026-05-27-itinerary-planner-empty-widget/` and
> `handoffs/archive/2026-05-27-itinerary-planner-spa-hang/`, but
> nothing in those rounds is load-bearing for this CLI work.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`.  Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`, `agents/rules/writing-style.md` (no
"canonical"), `agents/rules/logging.md`, and
`agents/rules/submodules.md` before starting.

## Motivation — friction observed in a live session

Operating the noetl CLI against the GKE cluster + Auth0 + gateway
combination revealed several rough edges that turned routine
credential / playbook registration into a multi-step puzzle:

1. **In-place context update is missing.**  The existing
   `gke-prod` context was added historically with only
   `auth0_domain` set, no `auth0_client_id`.  Running
   `noetl auth login --browser-pkce` against it failed with:
   ```
   Error: Auth0 client_id not set. Use 'noetl context add --auth0-client-id <id>' first.
   ```
   The user's only path was `noetl context delete gke-prod` →
   `noetl context add gke-prod --server-url=… --auth0-domain=…
   --auth0-client-id=… --auth0-redirect-uri=… --set-current`.
   Six flags to retype because one was missing.

2. **Auth0 Allowed Callback URLs gotcha.**  After re-adding the
   context with the SPA's client_id, PKCE login still failed with
   ```
   Callback URL mismatch.
   The provided redirect_uri is not in the list of allowed callback URLs.
   ```
   The browser flow uses `http://127.0.0.1:8765/callback` (or
   whatever `--pkce-port` is) but Auth0's app config only had the
   SPA's production callback registered.  No CLI warning, no
   pre-flight hint, no Auth0 dashboard link in the error.

3. **No gateway-runtime-contract bootstrap.**  The gateway already
   exposes `GET /api/runtime/contract` (see
   `repos/gateway/src/main.rs:211` and `:278`).  That endpoint
   carries the Auth0 config the gateway uses to validate session
   tokens.  The CLI doesn't consume it.  Operators who know the
   gateway URL still have to look up the SPA's source to find the
   right client_id, redirect URI, and audience.

4. **Stale-cached-token UX is rough.**  If the cached gateway
   session token expired, every `noetl <subcommand>` against the
   gateway context fails with a generic 401 instead of a
   structured "run `noetl auth login` first" hint.

5. **Direct-server port-forward dance is manual.**  The
   `gke-pf` context's server URL is `http://127.0.0.1:18082`,
   which only works while a separate terminal runs
   `kubectl port-forward svc/noetl 18082:8082`.  Every session
   re-establishes the tunnel by hand.  Other tools (e.g. `tilt`,
   `skaffold`, k9s) own the port-forward themselves; the noetl
   CLI doesn't.

## Scope — five additive changes

All five land in `repos/cli/`.  Source is one ~6500-line
`main.rs` plus `config.rs` and `playbook_runner.rs`.  Context
storage uses `config.rs::Config` — the YAML at
`~/.config/noetl/config.yaml` (verify the path on inspection;
treat as authoritative once confirmed).

### Change 1 — `noetl context update <name> [flags]`

Add an `Update` variant to `ContextCommand` mirroring `Add` but
where the context must already exist.  Every flag is optional;
unspecified fields are preserved.

```
noetl context update gke-prod \
    --auth0-client-id=Jqop7YoaiZalLHdBRo5ScNQ1RJhbhbDN
noetl context update local --runtime=local
noetl context update gke-pf --server-url=http://127.0.0.1:18082
```

Validation: refuse if the context doesn't exist (suggest
`noetl context add`).  Refuse `--server-url=""` (empty).  No
flag combinations beyond what `Add` already accepts.

Add a unit test under `repos/cli/tests/` (or however the CLI
expresses its tests today — check `Cargo.toml` for any existing
`[[test]]` blocks first).

### Change 2 — `noetl context init <name> --from-gateway <url>`

Bootstrap a new context from the gateway's `/api/runtime/contract`
endpoint.  The endpoint shape (verify against the deployed
gateway image `client-absent-log-20260527212936` —
`kubectl -n gateway exec deploy/gateway -- ...` if you need to
print the live response) carries fields like:

- `auth0.domain`
- `auth0.client_id`     (may need to add this server-side — see
                         §Server-side §4 below)
- `auth0.audience`
- `auth0.redirect_uri`  (may need to add this server-side)
- `noetl.public_url`    (the gateway URL itself, for round-trip
                         confirmation)

If any required field is missing in the response, fail cleanly
with `--auth0-client-id` etc. shown as remediation flags so the
user can fall back to manual `noetl context add`.

```
noetl context init gke-prod --from-gateway https://gateway.mestumre.dev
# Inspect what would be set, prompt, then write
```

Add a `--non-interactive` / `--yes` flag for scripted use.

### Change 3 — Auto-refresh stale tokens

Today, the gateway-routed commands (`noetl --context gke-prod
catalog list ...`) blindly use whatever token is cached.  If
the gateway returns HTTP 401, the CLI surfaces a generic error.

After this change: on 401 from a gateway-routed call, the CLI
should print:

```
Cached session token expired (HTTP 401 from gateway).
Run: noetl auth login --browser-pkce --context gke-prod
```

Bonus: detect the 401 inside the gateway proxy wrapper and
exit with a distinct exit code (e.g. 77) so shell scripts can
match on it.

No automatic refresh in this round — the user explicitly
re-authenticates.  (A future round can add a refresh_token
exchange.)

### Change 4 — Pre-flight Auth0 callback URL check

Before opening the PKCE browser flow, the CLI knows the
`redirect_uri` it will use (`http://127.0.0.1:<pkce_port>/callback`).
Hit the Auth0 tenant's well-known config
(`https://<auth0_domain>/.well-known/openid-configuration`) and
also try Auth0's `GET /api/v2/clients/{client_id}` if a
management API token is available — *but the management API
token usually isn't, so this is a soft check*.

What's achievable without management API access:

- Before opening the browser, print the `redirect_uri` the CLI
  will use.
- If the PKCE callback fails with a 400 / "Callback URL
  mismatch" type response, surface a structured hint:
  ```
  Auth0 rejected the PKCE callback.  This usually means
  http://127.0.0.1:8765/callback is not in the Allowed
  Callback URLs list for client_id Jqop7YoaiZalLHdBRo5ScNQ1RJhbhbDN.

  Add it at:
    https://manage.auth0.com/dashboard/<tenant>/applications/<client_id>/settings

  Or pick a different port: noetl auth login --browser-pkce --pkce-port 9876
  ```

### Change 5 — CLI-managed port-forward for direct contexts

For contexts whose `server_url` matches `http://127.0.0.1:*`
or `http://localhost:*` AND the context has a
`kube_context` + `kube_namespace` set (new optional fields),
expose:

```
noetl context port-forward gke-pf [--detach]
noetl context port-forward gke-pf --stop
```

The detach flag spawns `kubectl --context <ctx> -n <ns>
port-forward svc/noetl <local-port>:<remote-port>` as a daemon,
writes the PID to `~/.config/noetl/port-forwards/<context>.pid`,
and exits.  `--stop` reads the PID and kills it.

Without these new fields, `noetl context port-forward` errors
cleanly with the kubectl command the user can run manually.

Update `ContextCommand::Add` and `ContextCommand::Update` to
accept the new optional flags:
- `--kube-context <ctx>`
- `--kube-namespace <ns>`
- `--kube-service <name>`  (default: `noetl`)
- `--kube-remote-port <port>`  (default: 8082)

## Server-side §4 — gateway runtime contract extension

The CLI Change 2 needs the gateway to actually serve auth0
client_id + redirect URI from `/api/runtime/contract`.  Inspect
the current response:

```
curl -s https://gateway.mestumre.dev/api/runtime/contract | jq
```

If the response already includes them, skip this section.
Otherwise:

- Extend the gateway's `runtime_contract` handler in
  `repos/gateway/src/main.rs` (search for the existing
  `runtime_contract` symbol) to include:
  ```json
  {
    "auth0": {
      "domain": "<from gateway config>",
      "client_id": "<from gateway config>",
      "audience": "<from gateway config>",
      "redirect_uri": "<from gateway config>"
    },
    "noetl": {
      "public_url": "<gateway public URL>"
    }
  }
  ```
- Source the values from the gateway's existing
  `GatewayConfig` struct (do NOT add new env vars unless the
  fields really aren't represented).
- Add a unit test under `repos/gateway/tests/` or in the
  module's `#[cfg(test)]` block.

If you find that the gateway config doesn't carry these (e.g.
the SPA's client_id is read by the SPA at build time and the
gateway never sees it), document the gap in the result file
and open a separate noetl/ops PR to plumb them through the
Helm chart values.  Don't block CLI changes 1, 3, 4, 5 on the
server-side work — they each stand alone.

## Phases

### Phase A — read-only audit (no remote writes)

1. Sync `repos/cli`, `repos/gateway` to `main`:
   ```
   git -C repos/cli fetch origin && git -C repos/cli checkout main && git -C repos/cli pull --ff-only
   git -C repos/gateway fetch origin && git -C repos/gateway checkout main && git -C repos/gateway pull --ff-only
   ```
2. Read `repos/cli/src/main.rs` around line 937 (ContextCommand
   enum), line 1015 (AuthCommand enum), line 2292
   (handle_context_command) and the surrounding handler functions.
3. Read `repos/cli/src/config.rs` end-to-end (only 89 lines).
4. `curl -s https://gateway.mestumre.dev/api/runtime/contract |
   jq` and record the actual shape.  This determines whether
   Server-side §4 is needed.

### Phase B — implement CLI changes 1 + 3 + 5

Branch `kadyapam/cli-context-update-and-auth-hints` off
`repos/cli` `main`.  Land in one PR.

5. Change 1 — `noetl context update`.
6. Change 3 — 401-on-gateway hint + distinct exit code.
7. Change 5 — `noetl context port-forward` (additive — the new
   fields default to None and the command errors cleanly if
   unset).
8. Unit tests for each change.  Run `cargo test`.
9. Update CLI README (`repos/cli/README.md`) with the three
   new flows.

### Phase C — implement CLI change 2 + gateway change (gated on Phase A finding)

10. If `/api/runtime/contract` already carries Auth0 client_id +
    redirect_uri, implement Change 2 in the same CLI PR.
11. If not, branch `kadyapam/gateway-runtime-contract-auth0`
    on `repos/gateway` first.  Add the fields + a test.  Open
    draft PR.  THEN implement Change 2 against the new shape
    in the CLI PR.

### Phase D — implement CLI change 4 (PKCE pre-flight hint)

12. Change 4 — runs on Auth0 401 from the PKCE listener.
    Same CLI PR as Phase B.

### Phase E — open draft PRs

13. Push branches, `gh pr create --draft` on each.
14. Each PR body:
    - Links to this handoff thread.
    - Lists the user-visible behaviour change.
    - Shows the before/after CLI session output for the
      friction case it addresses.

### Phase F — live verification (GATED)

> ***Run only after explicit human go-ahead. Wait phrase:
> `proceed with noetl cli release`.***

15. After PRs merge: rebuild the CLI binary
    (`cargo build --release` in `repos/cli`).  Distribute via
    whatever the existing release process is — DO NOT improvise;
    check `repos/cli/CHANGELOG.md` and the release workflow under
    `.github/workflows/` for the canonical path.
16. Smoke-test the five flows end-to-end against the deployed
    `gke-prod` and `gke-pf` contexts.
17. Record evidence in the result file.

## Hard rules

- Do NOT push to `main` on any repo.
- Do NOT merge any PR yourself.
- Phase F is gated on `proceed with noetl cli release`.
- No "canonical" in any prose or commit message.
- Do not store secrets in any file under ai-meta.
- The noetl CLI is consumed by other tooling; backward-compat
  matters.  Every change must be additive — don't change the
  shape of `noetl context add`, `noetl auth login`, etc.  New
  flags are fine; renamed flags break consumers.
- Per `agents/rules/logging.md` — no INFO on high-frequency
  paths in the CLI (it already prints to stderr at the right
  level; don't add new INFO spam).
- If preconditions are missing, stop and report.

## What success looks like

- `noetl context update <name> --auth0-client-id <id>` works
  in-place — no delete-and-re-add.
- `noetl context init <name> --from-gateway <url>` discovers
  Auth0 config from the gateway, prompts to confirm, writes
  the context.
- Stale gateway tokens produce a clear "run `noetl auth login`"
  hint with exit code 77.
- PKCE failure prints the exact Auth0 dashboard URL the user
  needs to update.
- `noetl context port-forward <name>` spawns + manages a
  kubectl port-forward for direct-server contexts (or errors
  cleanly if the kube fields aren't set).
- All changes are additive — no existing CLI command shape
  changes.

## FINAL REPORT

Always emit, even on early STOP.  Frontmatter:

```yaml
---
thread: 2026-05-28-noetl-cli-context-auth-ergonomics
round: 1
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Body sections (one H2 per phase plus the standard `Issues
observed` and `Manual escalation needed`):

```markdown
## Phase A — read-only audit
- ...

## Phase B — CLI changes 1 + 3 + 5
- ...

## Phase C — CLI change 2 (+ gateway extension if needed)
- ...

## Phase D — CLI change 4
- ...

## Phase E — open draft PRs
- ...

## Phase F — live verification (GATED)
- phase F blocked: awaiting "proceed with noetl cli release"

## Issues observed
- ...

## Manual escalation needed
- ...
```
