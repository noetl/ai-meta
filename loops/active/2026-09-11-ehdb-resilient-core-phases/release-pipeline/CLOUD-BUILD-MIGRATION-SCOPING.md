# Moving CI/release to Cloud Build — scoping pass

**Status: INVESTIGATION ONLY. Nothing was built, migrated or changed.**
Read-only throughout; no secret value was ever read (names only).
Written 2026-09-17.

**Recommendation up front: fix the GitHub Actions condition first. Do not
migrate yet.** Reasons below; the short version is that Actions is *free* for
these repos, Cloud Build is not, the migration cannot take arm64 with it, and it
would force a long-lived GitHub PAT that the current design deliberately avoids.

---

## 1. The existing Cloud Build footprint is not what it looks like

The premise was that images "already build via Cloud Build", so the rest could
follow incrementally. Measured:

| thing | finding |
| :-- | :-- |
| Cloud Build **triggers** in `shastaratech-noetl-prod` | **none** — checked `global`, `us-central1`, `us-east1`, `europe-west1` |
| Cloud Build **2nd-gen GitHub connections** | **none** |
| Google Cloud Build **GitHub App** | not installed (no connection exists) |
| how builds actually start | `gcloud builds submit` **called from the GitHub Actions job `publish-ar`**, authenticated by WIF |
| region / machine | `us-central1`, `E2_HIGHCPU_8`, 200 GB disk, 2400 s timeout |
| health | fine — latest build `11f173a2…` SUCCESS at 2026-09-16T21:22:36Z (the v6.0.0 image) |

**So Cloud Build today is a build *executor invoked by Actions*, not an
independent CI system.** Every GitHub-facing part — receiving events, posting
statuses, gating merges — is greenfield. The existing footprint makes the
*image build* incremental and nothing else.

Auth wiring, per repo: `GCP_WIF_PROVIDER` + `GCP_CLOUDBUILD_SA` are repo-level
Actions **variables** on `worker` and `server`. `tools` has neither (it
publishes a crate, not an image). Under Cloud Build triggers these variables
become irrelevant — the trigger runs as a Cloud Build service account — so the
auth model changes shape rather than moving across.

## 2. Can a Cloud Build status be the required check? Yes — with setup

Cloud Build's GitHub App posts a check run per trigger, and branch protection
can require that context, with GitHub Actions entirely out of the loop.

Needed, none of which exists today:

1. Install the **Google Cloud Build GitHub App** on the `noetl` org (or per repo).
2. Create a **host connection** and link each repository — the OAuth handshake
   is a console flow, **owner-only**.
3. Enable **`developerconnect.googleapis.com`** — currently **not enabled**
   (`cloudbuild`, `artifactregistry` and `secretmanager` are).
4. Create a **`pull_request` trigger** per repo running the test config.
5. Add the resulting check context to each repo's branch protection.

⚠ This also re-opens the question that started all of this: a required check
must actually *report*. Swapping which system reports it does not change that a
gate whose reporter is down blocks every merge.

## 3. What migrating each piece entails

| piece | portability | notes |
| :-- | :-- | :-- |
| `test` (cargo build/test/clippy, **2–6 min** per run) | **easy** | pure cargo on a Linux image; the natural first move |
| **semantic-release** (version, tag, GitHub Release) | **possible, but see below** | Node runs fine in a build step |
| amd64 image | **already there** | `cloudbuild.yaml`, unchanged |
| **arm64 image** | ⚠ **cannot move** | see below |
| crate publish | easy | `worker`'s is a no-op echo; `tools`/`cli` need `CRATES_IO_TOKEN` from GSM |

### ⚠ 3a. semantic-release on Cloud Build forces a long-lived PAT

Inside Actions, semantic-release authenticates with the **ephemeral
`secrets.GITHUB_TOKEN`**, scoped to one run. Cloud Build has no such thing. To
create tags and GitHub Releases it would need a **long-lived GitHub credential**
(PAT or GitHub-App token) stored in Secret Manager and mounted into the step.

That is a **worse credential posture than today**, and it is the very thing
option 3 (`worker#330`) was chosen to avoid. If a PAT is acceptable for Cloud
Build, then it is also acceptable for Actions — and using it there is a
*one-line* fix that needs no migration at all.

⚠ No GitHub PAT secret was found by name in `shastaratech-noetl-prod`,
`-noetl-dev`, `-sandbox` or `-web-prod`. If one exists the owner should name the
project and secret. **No secret value was read at any point.**

### ⚠ 3b. arm64 cannot follow, and that is documented in the repo

`cloudbuild.yaml` says it plainly: **Cloud Build offers no arm64 machine type.**
Every machine type is x86_64, so an arm64 build runs under QEMU — *6–10× slower*
for a Rust/cargo-chef build. That regression is precisely what
noetl/ai-meta#44 fixed by moving arm64 onto native `ubuntu-24.04-arm` runners.

So a "full" migration must pick one:

* **keep arm64 on Actions** → still dependent on Actions, migration incomplete;
* **build arm64 under QEMU on Cloud Build** → reintroduces a fixed regression;
* **drop arm64** → breaks local `kind` on Apple Silicon, which pulls the arm64
  image from GHCR. That is the everyday development loop.

None of the three is good. This is the single strongest argument against a full
migration.

## 4. Owner-gated

* Installing the Cloud Build GitHub App + the OAuth host connection (console).
* Enabling `developerconnect.googleapis.com`.
* IAM for the trigger service account (Secret Manager accessor, AR writer).
* A GSM secret holding a GitHub credential — **and the decision to use one**.
* ⚠ **GCP spend.** This is *GCP billing*, not a GitHub plan change. Note the
  direction of the trade: GitHub Actions standard **and arm64** runners are
  **free for public repositories**, and all four active repos are public. Today
  CI costs ≈ nothing; Cloud Build is metered per build-minute
  (`E2_HIGHCPU_8`, ~26 min for the release image, plus every PR's test run).
  **The migration converts free CI into paid CI.**

## 5. Risks that would make this worse than clearing the Actions condition

1. **It may not even sidestep the freeze.** If the cause is an account-level
   GitHub condition (see §6), it can equally affect the GitHub App that Cloud
   Build needs to post statuses and the API calls semantic-release needs to cut
   releases. Migrating could buy nothing.
2. **Free → paid**, for a system that currently costs nothing.
3. **arm64 loss or a 6–10× slowdown** (§3b).
4. **A long-lived PAT** replacing an ephemeral token (§3a).
5. **More systems, not fewer** — GHCR publishing and arm64 would likely stay on
   Actions, leaving two CI systems to maintain instead of one.
6. `ehdb` has no semantic-release at all (only `ci.yml`), so it needs a
   different treatment again.

## 6. The freeze: what is and is not established

**Established by measurement (16:09Z, 2026-09-17 — ~19 hours):**

| repo | last workflow run |
| :-- | :-- |
| worker | 2026-09-16T21:22Z |
| server / tools / cli | 2026-09-16T20:39Z |
| ehdb | 2026-09-16T12:44Z |

* `worker#330` has **no checks at all**; closing and reopening the PR created no run.
* Actions is **enabled at org level** (`enabled_repositories=all`,
  `allowed_actions=all`) **and repo level** (`enabled=true`).
* **0 queued, 0 waiting** runs. githubstatus.com reports Actions **operational**.
* ⚠ **Minutes exhaustion is ruled out:** the org's 6 private repos have
  **never** run Actions (no runs at all), and the 27 public repos draw on the
  free-for-public-repos allowance.

**Therefore:** it is org-wide, persistent, and *not* explained by policy or by
quota. The remaining candidates are an **account-level billing/payment
condition** or a **trust-and-safety / account restriction** — both visible only
on GitHub's billing and settings pages, which is owner-only. The billing REST
endpoints now return `410 moved`, so this cannot be narrowed further read-only.

⚠ Honest correction to my earlier read: I called a *spending limit* the most
likely cause. With private-repo usage now measured at zero and public-repo
minutes free, a plain spending limit is a **weaker** explanation than a payment
or account-level condition. Worth saying before anyone acts on the earlier guess.

## 7. Recommendation

**Fix the Actions condition first.** Check GitHub → org settings → Billing for a
payment failure, and the org/owner notifications for any account notice.
Minutes-to-hours, costs nothing, and keeps free CI, native arm64 and the
ephemeral token.

**If and only if GitHub says the suspension is durable**, migrate — and migrate
*incrementally*, smallest viable first:

> **Step 1 (the hedge): move only `test` to a Cloud Build `pull_request`
> trigger, and make its status the required check.** That restores the merge
> gate on its own. It needs no PAT, does not touch arm64, and leaves releases
> exactly where they are. It is also the piece that is cheap to run.

Only if releases must move too does §3a's PAT question and §3b's arm64 problem
have to be answered — and at that point, using the PAT on Actions instead is
strictly less work.

## 8. Orthogonal: option 3 survives either way

`worker#330` (the tag-authoritative release, `ci/stamp-version.sh`) is
**compatible with both**. It is a shell script plus workflow steps; under Cloud
Build the stamp becomes a build step calling the same script. Nothing in it
depends on Actions. It should be merged and proven whichever way this goes —
though it cannot be proven until *something* is running CI.
