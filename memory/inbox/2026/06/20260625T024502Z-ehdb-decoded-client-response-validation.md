# EHDB decoded client response validation

Date: 2026-06-25 UTC

Repository state:

- `noetl/ehdb#173` merged to `main` as
  `03c272f8b87b7a9d97d462990885a5fe0e0f07da`.
- Closed issue:
  [#172 Validate decoded Arrow Flight scan batches against schema result](https://github.com/noetl/ehdb/issues/172).
- Wiki updated as `f367421b7c44e2328c6c39018435a8ac71364b29`.

Summary:

- Added `ArrowScanResult::from_batches_for_schema_info_and_ticket` for
  already-decoded Arrow batches plus decoded `get_schema` schema,
  returned scan `FlightInfo`, and expected `ScanFlightTicket`.
- Loopback Arrow Flight client smoke paths now validate decoded batches
  through that helper before treating `do_get` output as coherent.
- README and wiki architecture/roadmap/session notes document the
  decoded client response validation boundary.

Boundary:

- Local Arrow Flight decoded client response receiver-side validation
  only.
- No Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions rust check passed on PR #173.
