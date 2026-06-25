# EHDB do_get endpoint ticket binding

Date: 2026-06-25 UTC

Repository state:

- `noetl/ehdb#179` merged to `main` as
  `f1a7e197f3507deca4bc3e7084f4b65d1b980c0b`.
- Closed issue:
  [#178 Validate Arrow Flight do_get endpoint ticket binding](https://github.com/noetl/ehdb/issues/178).
- Wiki updated as `a76d55a8bac4e9e397d194c39cfd4a1b33b6e888`.

Summary:

- Added `ScanFlightTicket` helpers to validate a supplied Arrow Flight
  endpoint `Ticket` against returned scan `FlightInfo`, decoded schema,
  and the expected scan ticket.
- Local service/server and loopback client receiver paths now validate
  the concrete `do_get` endpoint ticket before accepting `do_get`
  results as coherent.
- README and wiki architecture/roadmap/session notes document the
  endpoint-ticket receiver boundary.

Boundary:

- Local Arrow Flight endpoint-ticket receiver-side validation only.
- No Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #179.
