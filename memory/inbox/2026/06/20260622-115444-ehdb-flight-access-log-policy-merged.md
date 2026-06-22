# EHDB Bounded Flight Access Logs Merged

Date: 2026-06-22

Repository: `noetl/ehdb`

Issue: https://github.com/noetl/ehdb/issues/66

Pull request: https://github.com/noetl/ehdb/pull/67

Merged code SHA: `0bce4ae6ca18f678bbe580bbee8f4b1e4b51850e`

Wiki SHA: `ae13d050d335b0a453038e44b9a34fc1f7b033c9`

Branch: `kadyapam/ehdb-flight-access-log-policy`

Summary:

- Added bounded local Arrow Flight scan access summaries for decoded
  `get_flight_info` and `do_get` requests.
- Added `FlightScanAccessLogEntry` and `FlightScanAccessLogInput`.
- Wired `FlightAccessLogPolicy` through `LocalArrowFlightServerConfig`
  into the generated service adapter.
- Kept default local-reference logging DEBUG-only and added disabled
  mode that emits no scan access summaries.
- Excluded auth tokens, principal values, tenant/table identifiers,
  object paths, predicate values, and Arrow payloads from the summary
  contract.
- Added direct policy/config tests.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #67 in 3m08s.

Coverage:

- 120 Rust tests across unit, integration, and doc-test targets.

Boundary:

- This is local reference observability only.
- No non-loopback exposure, production IAM, gateway direct reads, SQL
  planning, predicate pushdown, distributed execution, high-volume INFO
  logs, tenant data logging, or persistent per-tenant service process was
  added.
