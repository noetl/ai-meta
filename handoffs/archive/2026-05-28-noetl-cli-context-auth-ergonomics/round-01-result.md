---
thread: 2026-05-28-noetl-cli-context-auth-ergonomics
round: 1
from: claude
to: claude
created: 2026-05-28T02:25:00Z
in_reply_to: round-01-prompt.md
status: partial
---

Round 01 ran in two stages.  First an attempt to delegate to codex
hit a permissions wall (codex's profile in this session does not
have Bash tool access, so the multi-file Rust work could not
proceed via the delegate path).  The dispatcher (claude) then
took over and shipped Changes 1, 3, and 4 in a single CLI PR.
Changes 2 (``--from-gateway``) and 5 (``port-forward``) are
deferred to a Round 02 with reasons documented below.

## Phase A — read-only audit

Synced `repos/cli` and `repos/gateway` to `main`.  Read
`repos/cli/src/main.rs` around lines 937 (ContextCommand enum),
1015 (AuthCommand enum), 2292 (handle_context_command), 1881
(build_http_client), 2768 (wait_for_pkce_callback), 2876
(auth0_pkce_authorize), 3540-3577 (register_resource),
3623-3683 (execute_playbook_distributed), 4181-4211
(list_resources).  Read `repos/cli/src/config.rs` end-to-end.

Probed the live gateway:

```
curl -s https://gateway.mestumre.dev/api/runtime/contract | jq 'keys'
[
  "agent_contract",
  "cli_operation_mapping",
  "contract_version",
  "execution_contract",
  "gateway_version",
  "proxy_contract",
  "routes",
  "summary"
]
```

No `auth0` block in the contract response.  Read
`repos/gateway/src/main.rs::runtime_contract` (line 296) — the
handler builds a hard-coded JSON literal that doesn't reference
any Auth0 fields.  Grepped `repos/gateway/src/auth/mod.rs:67`:
the auth0_domain is read per-request from the login payload,
not stored on `GatewayConfig`.  Neither
`repos/gateway/config/gateway.example.yaml` nor the deployed
Helm values carry Auth0 client_id / redirect_uri / audience.

**Finding:** `noetl context init --from-gateway <url>` (Change 2)
cannot discover Auth0 config without either:
- Adding `auth0:` to GatewayConfig + plumbing through Helm
  values + ConfigMap, then exposing in `runtime_contract`, or
- Routing CLI to a dedicated endpoint backed by the same config

Either path is a noetl/gateway + noetl/ops change ahead of the
CLI work.  Out of scope for Round 01.

## Phase B — CLI changes 1 + 3 + 5

Implemented Changes 1 and 3.  Change 5 deferred — see Manual
escalation.

### Change 1 — `noetl context update <name>`

Added `ContextCommand::Update` enum variant + handler at
`repos/cli/src/main.rs:978-1011` and `:2445-2517` respectively.
All flags optional.  Refuses if the context doesn't exist;
suggests `noetl context add` with the right slug.  Empty-string
clears the relevant Auth0 field, mirroring the existing
clear-on-empty pattern in `Add` for audience + client_secret.

Verified the new command surfaces:

```
$ target/debug/noetl context update --help
Update an existing context's settings in place.  All flags are
optional; unspecified fields are preserved.  Refuses if the
context does not exist (suggests ``context add``).
Examples:
    noetl context update gke-prod --auth0-client-id=abc123
    noetl context update gke-pf --server-url=http://127.0.0.1:18082
    noetl context update local --runtime=local
    noetl context update gke-prod --auth0-audience=""   # clear
…
```

### Change 3 — Gateway 401 → exit code 77 + structured re-auth hint

Added `GATEWAY_AUTH_EXPIRED_EXIT_CODE = 77` constant and
`check_gateway_auth_expired(status, use_gateway_proxy,
current_context_name)` helper at `repos/cli/src/main.rs:1881-1923`.
Wired into three highest-traffic gateway-proxied call sites:

- `register_resource` (credentials + playbooks) — line 3604.
- `execute_playbook_distributed` (the `exec` command) — line 3691.
- `list_resources` (catalog list) — line 4220.

On HTTP 401 against a gateway-proxied call:

```
Cached gateway session token expired (HTTP 401).
  Run: noetl auth login --browser-pkce --context <current>

Exit code 77 is reserved for this case so shell scripts can detect it.
```

and exits 77.  The current-context name is passed as `None` from
all wired sites — the handler degrades gracefully and prints the
generic hint without `--context <name>`.  Threading the context
name through every call site is left for a Round 02 followup.

### Change 5 — `noetl context port-forward` — DEFERRED

Larger scope than 1, 3, 4 combined:
- 4 new optional Context fields (`kube_context`,
  `kube_namespace`, `kube_service`, `kube_remote_port`) on
  `repos/cli/src/config.rs::Context`
- New CLI subcommand with `--detach` / `--stop` semantics
- Daemon process management (PID file at
  `~/.config/noetl/port-forwards/<context>.pid`, signal
  handling, orphan detection)
- New tests covering daemon lifecycle

Defer to a focused Round 02 thread — the current PR already
hits 310 lines of additions and the daemon code is conceptually
independent of Changes 1, 3, 4.

## Phase C — CLI change 2 (`--from-gateway`) — DEFERRED

Blocked on the Phase A finding (gateway runtime contract
doesn't expose Auth0 config and GatewayConfig doesn't carry it).
Two-step path for Round 02:

1. Open noetl/ops PR adding `auth0.client_id`,
   `auth0.redirect_uri`, `auth0.audience` to the gateway's
   Helm values.yaml + ConfigMap.
2. Open noetl/gateway PR extending `GatewayConfig` to read
   those values + extending `runtime_contract` to expose them.
3. THEN implement Change 2 in noetl/cli.

The CLI's `--from-gateway` flag would simply GET the contract,
parse the auth0 block, prompt the user to confirm, and write
the context via the same `Update` handler shipped in Change 1.
Should be a thin layer once the gateway exposes the data.

## Phase D — CLI change 4 (PKCE callback URL hint)

Two parts implemented, both in `repos/cli/src/main.rs`.

### Pre-flight notice (line 2944-2961)

`auth0_pkce_authorize` now prints the exact redirect URI it
will use, the Auth0 dashboard URL where it must appear in the
application's allowed list, and a NOTE explaining the failure
mode if the URI isn't allowed:

```
PKCE callback listener ready at 127.0.0.1:8765
Redirect URI: http://127.0.0.1:8765/callback
  NOTE: this URI must appear in the Auth0 application's
        "Allowed Callback URLs" list, otherwise Auth0
        will reject the /authorize request with a
        "Callback URL mismatch" page and this CLI
        will hang until timeout.  Manage Allowed
        Callback URLs at:
        https://manage.auth0.com/dashboard/<tenant>/applications/<client_id>/settings
Open this URL to authenticate:
  https://<domain>/authorize?...
```

### Timeout hint (line 2810-2884)

New `wait_for_pkce_callback_with_hint` wrapper that calls the
existing `wait_for_pkce_callback` and, on any error, prints
the structured remediation block before propagating the
original anyhow error.  Most common cause: Auth0 rejected
the `/authorize` request because the redirect_uri isn't in
the application's allowed list, so the CLI's listener
never receives a callback and times out after 5 minutes.

### Tenant slug extraction

Added `extract_auth0_tenant_from_domain(domain) -> Option<String>`
helper for building the Auth0 dashboard URL from the domain.
Handles:
- Standard `<tenant>.auth0.com` shape
- Regional `<tenant>.<region>.auth0.com` shapes (eu, us, au, jp)
- CNAMEd custom domains → returns `None`, falls back to
  literal `<tenant>` placeholder in the hint

## Phase E — open draft PR

**noetl/cli PR #13:** <https://github.com/noetl/cli/pull/13>
- Branch: `kadyapam/cli-context-update-and-auth-hints`
- Status: draft
- Diff stat: `src/main.rs | 310 +++++++++++++-` (310 insertions,
  1 deletion).
- Body cross-links this handoff thread and includes before/after
  CLI session output for each of the three changes.

No noetl/gateway or noetl/ops PR this round — Phase C scope
moved entirely to Round 02.

## Phase F — live verification (GATED)

`phase F blocked: awaiting "proceed with noetl cli release"`

When the gate phrase is given, the release flow is:
- `cargo build --release` in `repos/cli/`
- Distribute the binary via whatever the existing release
  process is (check `.github/workflows/release.yml` and
  `CHANGELOG.md` — there's a semantic-release flow per the
  `.releaserc.json` pattern visible in noetl/gateway).
- Smoke-test the three flows against the deployed `gke-prod`
  and `gke-pf` contexts.

## Issues observed

1. **Codex permissions gap (third time tonight).**  Same gap as
   the 2026-05-27 SPA-hang rounds 02 + 03.  This is the third
   round where the dispatcher takes over because codex can't
   run Bash.  Worth either permanently granting codex Bash
   access in this workspace OR documenting in
   `agents/profiles/` that any submodule-code round must be
   dispatched to claude (not codex) by default.

2. **Gateway runtime contract is hard-coded literal.**  The
   `runtime_contract` handler at `repos/gateway/src/main.rs:296`
   ships a static `json!({...})` body that references no
   GatewayConfig fields.  Future contract changes will need
   the handler refactored to read config.  Worth a focused
   gateway refactor PR before Change 2 lands.

3. **Pre-existing warnings on `cargo build`.**  `ExecutorSpec`
   has dead `Clone` + `Debug` derives unrelated to this PR.
   Not introduced by this work — already present on `main`.

4. **Test names use the new `tests` module convention.**  Five
   new unit tests cover the helpers; integration tests covering
   the new ContextCommand::Update handler would require a
   tempdir-based Config harness which doesn't currently exist
   in the crate.  Adding that harness is its own round.

## Manual escalation needed

1. **Round 02 — Change 2 + Change 5** as scoped above.  Two
   sub-PRs (gateway + ops for Change 2 prerequisites) plus the
   CLI work.

2. **Threading current-context name into all gateway-proxied
   call sites.**  The `check_gateway_auth_expired` helper
   already accepts `Option<&str>` for the context name but every
   call site currently passes `None`, so the hint shows the
   generic "run noetl auth login" instead of "run noetl auth
   login --context <name>".  Plumbing the name through is
   mechanical; not done in this round to keep the diff bounded.

3. **Phase F (release + smoke test) is gated** on the wait
   phrase `proceed with noetl cli release`.  Per the round-01
   prompt, do not run until the human gives the phrase.
