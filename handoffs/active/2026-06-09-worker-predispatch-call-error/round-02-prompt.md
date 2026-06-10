---
thread: 2026-06-09-worker-predispatch-call-error
round: 2
from: claude
to: codex
created: 2026-06-10T00:00:00Z
expects_result_at: round-02-result.md
tracks: noetl/ai-meta#78
status: open
wait_phrase: "ship the worker fix"
---

# Addendum to round 01 — fold the `noetl-tools` dep revert into the #78 PR

This round does **not** change the worker bug fix described in
`round-01-prompt.md`. It supersedes exactly one instruction in that
prompt's **Background** section and adds one file to the PR. The wait
phrase is unchanged (`ship the worker fix`); everything here is still
gated behind it.

## What changed since round 01

When round 01 was written, crates.io was stuck at `noetl-tools 3.0.0`
(the v3.1.0 release commit carried `[skip ci]`, so the publish CI never
fired). That is no longer true:

```
$ curl -s https://index.crates.io/no/et/noetl-tools | tail -1
{"name":"noetl-tools","vers":"3.1.0",...}
```

`noetl-tools 3.1.0` is now published. Verified 2026-06-10 against the
crates.io sparse index.

## Superseding instruction (replaces the round-01 "Known local-only
## state — do not commit or revert" bullet)

Round 01 told you to **keep** `noetl-tools = { path = "../tools" }` in
the working tree and **exclude** that line from the commit. Reverse
that:

- Revert `repos/worker/Cargo.toml` `noetl-tools = { path = "../tools" }`
  back to `noetl-tools = "3"` (there are **two** occurrences — main
  deps around L99 and a second around L195; revert both to the
  published-crate form to match whatever the surrounding deps use).
- Let `Cargo.lock` re-resolve to `noetl-tools 3.1.0` from crates.io and
  **include** the lockfile churn in the commit.
- This revert ships **in the same PR** as the #78 fix — do not split it
  into a separate PR.

If reverting both occurrences cleanly proves impossible (e.g. the file
shape differs from what's described), stop and report rather than
guessing.

## Why bundle, not separate

The dep revert is a one-line-each change that only builds cleanly once
3.1.0 is on crates.io; it touches the same worker crate and the same
kind-revalidation cycle as the #78 fix. Shipping them together means one
worker image build, one kind validation, one pointer bump. Decision made
by the user 2026-06-10 ("bundle into #78 PR").

## Result

When the gate lifts and you complete the work, write a single
`round-02-result.md` covering **both** the #78 error-propagation fix
(all phases from round 01) **and** this dep revert. Note the resolved
`noetl-tools` version from `Cargo.lock` and confirm the worker image
still builds + passes kind validation with the published crate.
