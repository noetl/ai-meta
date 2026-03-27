# noetl/cli issue draft: Codex Runtime Program (M1)

- Date: 2026-03-27
- Repo: `noetl/cli`
- Issue: https://github.com/noetl/cli/issues/4
- Labels: `program:codex-runtime`, `area:cli`, `type:feature`, `priority:p0`

## Proposed title

`feat(cli): add noetl codex passthrough and noetl ai bootstrap (M1)`

## Problem summary

`noetl` needs to encapsulate full Codex CLI capability while keeping existing NoETL command behavior intact and backward compatible.

## Requested direction

- Add `noetl codex ...` pass-through with argument/stdio/tty parity to upstream `codex`.
- Add `noetl codex doctor` for install/auth/version checks.
- Add `noetl ai` command scaffold for NoETL-aware sessions.

## Acceptance criteria

- `noetl codex --help` matches direct `codex --help` behavior (output differences only from wrapper banner, if any).
- `noetl codex exec ...` and interactive modes pass stdin/stdout/stderr and return exit codes transparently.
- `noetl ai` starts and loads bootstrap context skeleton without breaking existing commands.
- Unit/integration tests added for pass-through argument and exit-code handling.

## Dependencies

- Paired `noetl/gateway` issue for runtime contract alignment.
- Program plan: `playbooks/noetl-codex-cli-gateway-program-plan.md`.

## Related

- `sync/noetl-codex-change-requests.md` (`CR-20260327-1`)
