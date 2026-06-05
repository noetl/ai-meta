# Standing direction: Rust-only focus, ignore Python tasks
- Timestamp: 2026-06-05T00:56:07Z
- Author: Kadyapam
- Tags: direction,rust,python,phase-f,strategic

## Summary
User directive 2026-06-04: 'ignore any python related tasks. We need working rust implementation.'  Stop investing in Python pytest debt triage (noetl/noetl#663), Python server bug-hunting, Python tooling cleanup, Pydantic schema work, and Python worker validation tiers.  Focus all forward work on getting the Rust stack to a 'working' end-to-end state: noetl-server-rust + noetl-worker-rust + noetl-gateway + noetl-cli, with the tool registry from noetl-tools.  Python pieces stay deployable for backwards-compat (existing GKE deployments, the dashboard SPA) but are NOT a target for new work.  Practical consequences: (a) Phase F R5 regression tiers 1-4 drop the Python pytest tier; only Tier 1 (Rust unit), Tier 3 (kind validation rigs), Tier 4 (E2E playbooks on Rust-only stack) count toward R5 completion. (b) Any newly-surfaced Python bug gets logged to a tracking issue with the deprioritized label rather than fixed inline. (c) When a Rust gap forces a choice between 'patch Python to bridge' vs 'finish Rust feature', pick finish-Rust. (d) The Rust worker's call-down into Python tools (today's hello_world used tool_kind=python) stays as the bootstrap path until tool_kind coverage in noetl-tools is wide enough to retire it; do not invest in expanding the Python tool surface beyond what's needed for that bootstrap.

## Actions
-

## Repos
-

## Related
-
