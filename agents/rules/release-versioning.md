# Release versioning — semantic-release owns the version

Every Rust submodule that carries a `semantic-release.yml` workflow has
**one** version authority: semantic-release. This rule exists because
it briefly had two, and they fought.

## The rule

**Never hand-edit `version` in `Cargo.toml`, and never push a release
tag by hand.**

Merge the PR with a conventional-commit subject and stop. semantic-release
runs on the push to `main`, computes the version from the commit
messages, rewrites `Cargo.toml`, commits, tags, and dispatches
`release.yml`.

| you write | it releases |
| :-- | :-- |
| `fix: …` | patch |
| `feat: …` | minor |
| `feat!: …` / `BREAKING CHANGE:` in the body | major |
| `chore:` / `docs:` / `test:` | no release |
| **anything else** (`diag:`, `wip:`, `refactor:`, a bare subject) | **no release, silently** |

That last row is a trap worth naming, because it costs a build cycle to
discover. `diag(209): …` was merged expecting an image; semantic-release ran,
chose no version, and produced nothing. The merge was green, CI was green, and
the tag simply never appeared — so the change sat on `main`, correct and
undeployable, with nothing anywhere saying why.

**If a change needs to reach a cluster, it needs a release-triggering type.**
When the work is genuinely diagnostic, `fix:` is the honest one — a missing
signal *is* a defect in the thing being diagnosed. Do not invent a type; check
the tag after the merge:

```bash
gh run watch --repo noetl/<repo>
git fetch origin --tags && git tag --sort=-v:refname | head -1   # did it move?
```

Read the tag back after the run rather than assuming it:

```bash
gh run watch --repo noetl/<repo>
git fetch origin --tags
git tag --sort=-v:refname | head -1
```

Everything downstream — the image tag, the `crane` GHCR→AR copy, the
ai-meta pointer bump — takes that value as an input. Do not decide the
version in advance and work backwards to it.

## Why — the 2026-08-03 regression

`release.yml` has a `verify-version` job that hard-fails when the pushed
tag and `Cargo.toml` disagree. A runbook step read that as "so bump
`Cargo.toml` manually before tagging". Both authorities then acted on the
same merge:

```
22:28:24  PR #211 merged as ddb4de8            Cargo.toml = 5.92.0  (manual bump)
22:28:48  semantic-release pushes b11e6d5      Cargo.toml = 5.91.3  + tag v5.91.3
~22:29    tag v5.92.0 pushed by hand           release.yml runs, verify-version OK
```

semantic-release computed a patch bump from 5.91.2 with no knowledge of
the manual bump. Results:

- `main` claimed **5.91.3**, *lower* than the newest published tag
  **v5.92.0**, and lower than what prod was running.
- Two images with byte-identical code: `:5.91.3` and `:5.92.0`.
- The next automatic release would compute ~5.91.4, sorting **below**
  5.92.0 — every subsequent release inheriting the problem.

Not a production incident: the deployed image was built from the
`v5.92.0` tag and rolled **by digest**, so prod was unaffected. The
damage was to the version line, and it took two further releases
(5.92.1, 5.92.2) to climb back above it.

`verify-version` is not the problem and should stay. Under this rule it
passes by construction: the commit semantic-release tags is the one
carrying the matching version.

## Merge style

**Merge commits, not squash.** These repos forbid squash. Beyond that,
the merge subject is what semantic-release reads, so it must be
conventional:

```bash
gh pr merge <n> --repo noetl/<repo> --merge
```

## When this rule doesn't fire

- Submodules with no `semantic-release.yml` — there the tag is the only
  authority and a manual bump is correct. Check before assuming.
- The first commit that *introduces* versioning to a new crate.
- `Cargo.lock` updates, which are not version declarations.

## Related

- [`commit-conventions.md`](commit-conventions.md) — the conventional
  prefixes semantic-release reads.
- [`deployment-validation.md`](deployment-validation.md) — the released
  tag is what kind validation and the prod roll consume.
- [ai-meta#224](https://github.com/noetl/ai-meta/issues/224) — the
  incident this rule closes.

## History

Codified 2026-08-04 while correcting `playbooks/223-ehdb-prod-runbook`
P1a, which still instructed the manual bump that caused the regression.
