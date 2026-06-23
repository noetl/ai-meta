# EHDB Stream Subject Filter Type

- Time: 2026-06-23T18:25:10Z
- Repository: `noetl/ehdb`
- Issue: https://github.com/noetl/ehdb/issues/120
- PR: https://github.com/noetl/ehdb/pull/121
- Merged EHDB SHA: `8031f94d8c93cb2c5b2b72eb96b87d54780c5e72`
- Wiki SHA: `9c376137d710fd362aad4c6dab545c8d460a03be`

## Summary

Separated concrete stream subjects from replay subject filters:

- `Subject::new` rejects wildcard tokens `*` and `>` for published
  stream record subjects.
- `SubjectFilter` supports exact selectors, single-token `*` wildcards,
  and terminal `>` tail wildcards.
- Misplaced `>` and partial wildcard tokens are rejected when a
  `SubjectFilter` is constructed.
- Filtered replay APIs now accept `SubjectFilter` instead of concrete
  `Subject`.

## Validation

- `cargo fmt --all --check`
- `cargo test --workspace`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo bench --workspace --no-run`
- GitHub Actions `rust` check passed on PR #121.

## Boundary

This remains local stream log validation and replay only. No durable
subject subscription, scheduler, background stream processing, NATS
bridge, network API, gateway route, distributed stream storage,
production replication, or persistent per-tenant service process was
added.
