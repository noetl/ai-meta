# Blueprint Appendix H.9 added: Polars-pattern endpoint locks in Rust+Python wrapper
- Timestamp: 2026-05-30T02:15:06Z
- Author: Kadyapam
- Tags: rust,polars-pattern,pyo3,migration,endpoint,issue-30

## Summary
User insight changes R-4 from a deferred decision into a planned ship date. Endpoint shape: pip install noetl ships PyO3 wrapper + embedded Rust binaries, preserving the existing noetl/noetl Python API surface so users migrate by upgrade not rewrite. Three Python surfaces: noetl (wrapper+runtime), noetl-sdk (pure-Python remote client), noetl-tools-python (Python callable tools via PyO3 with zero-copy Arrow). Same pattern as Polars replacing pandas. Reference projects: Polars, Pydantic V2 (pydantic-core), Ruff, Ty, maturin. FFI: control plane crosses PyO3 once per invocation, Rust tools never cross, Python tools cross once per command with Arrow zero-copy. Tradeoffs honoured: wheel size ~30MB, cibuildwheel for multi-platform, GIL coordination, PyO3 abi3. R-4 ship criterion sharpened. R-5 placeholder: delete Python control-plane code paths post-migration. PR noetl/docs#174 updated with H.9 (commit e338068).

## Actions
-

## Repos
-

## Related
-
