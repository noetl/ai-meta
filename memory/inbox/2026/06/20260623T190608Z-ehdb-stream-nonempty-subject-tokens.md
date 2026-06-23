# EHDB Stream Non-Empty Subject Tokens

- Time: 2026-06-23T19:06:08Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/122
- PR: https://github.com/noetl/ehdb/pull/123
- Merged EHDB SHA: `17c1644994cc39f97d1e29d40174cd2c2e4f547e`
- Wiki SHA: `7bb4f2992ad0b2ceba59917f9a886e382380132d`

## Summary

Rejected empty dot-delimited stream subject tokens:

- `Subject::new` rejects leading, trailing, and double-dot empty tokens.
- `SubjectFilter::new` rejects leading, trailing, and double-dot empty
  tokens.
- Valid concrete subjects and valid exact/wildcard filters continue to
  work.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #123.

## Boundary

This remains local stream log validation only. No durable subject
subscription, scheduler, background stream processing, NATS bridge,
network API, gateway route, distributed stream storage, production
replication, or persistent per-tenant service process was added.
