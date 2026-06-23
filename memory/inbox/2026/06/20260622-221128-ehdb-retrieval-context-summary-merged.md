# EHDB retrieval context execution summaries merged

- UTC time: 2026-06-23T05:11:28Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/90
- PR: https://github.com/noetl/ehdb/pull/91
- EHDB merged SHA: `98508dd15a7bb50bb5c2296da19a31a826808610`
- EHDB wiki SHA: `de4fa24747f7522cddc784ca9828b83bf71e20ff`
- ai-meta pointer update target: `repos/ehdb` -> `98508dd`,
  `repos/ehdb-wiki` -> `de4fa24`

Summary:

- Added `RetrievalContextPayloadExecutionSummary` and
  `RetrievalContextPayloadExecution` to `ehdb-service`.
- Added summary-returning default, config-aware, and scope-aware local
  retrieval context payload executor APIs.
- Kept existing byte-returning executor APIs behavior-compatible by
  delegating through the summary path.
- Summary includes request/result byte counts, context block count,
  total text chars, truncation status, and whether local scope was
  required.
- Summary excludes tenant IDs, namespace values, query text, chunk text,
  tokens, embedding vectors, payload bytes, object paths, and
  principals.

Validation:

- `cargo fmt --all --check`
- `cargo test --workspace` (157 Rust tests)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`

Boundary:

- This remains redacted metrics/audit metadata for local
  worker/playbook tests only.
- No logging sink, network API, Arrow Flight retrieval endpoint, prompt
  engine, LLM invocation, ANN index, BM25 engine, learned ranker,
  gateway route, production IAM, ACL integration, retrieval daemon,
  distributed query engine, gateway direct data path, scheduler, or
  persistent per-tenant process was added.
