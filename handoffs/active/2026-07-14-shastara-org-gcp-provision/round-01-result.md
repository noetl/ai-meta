---
thread: 2026-07-14-shastara-org-gcp-provision
round: 1
from: claude
to: user
created: 2026-07-14T00:00:00Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase A — shastara-org GCP provisioning via the provider tool: inspect + design + plan

**Status `partial`** per the README definition — Phase A (inspect / design / plan)
ran in full and is reported below; Phase B (any real GCP mutation) is gated on the
wait phrase `implement provider tool` and was **not started**. No remote writes,
no GCP calls (not even read-only GET), no `gcloud`, no builds, no worker rebuild,
no kind/prod actions. Only read-only inspection of the two repos + writing these
two handoff files.

**Where this lives / why (file-clobber resolution):** the round-1 prompt named
`2026-07-13-noetl-cloud-provider-tools/round-01-result.md`, but that file already
holds the committed record of the **provider-tool implementation** work (design +
REST MVP, amended with the explicit-auth + REST decisions). Clobbering it would
destroy history. Per `handoffs/README.md` Hygiene ("one thread per topic — don't
reuse a thread for unrelated work; open a new one"), building the tool and
*applying it to shastara-org* are different topics. So this is a **new thread**,
`handoffs/active/2026-07-14-shastara-org-gcp-provision/`, with the user's brief
captured in `round-01-prompt.md` and this report in `round-01-result.md`. The old
thread is untouched.

---

## TL;DR

- The shastara-org playbooks are **6 `kind: shell` playbooks that `echo` JSON
  operation specs to stdout**. They do **not** call `kind: provider` — there is
  **zero wiring** from them to the tool yet. That's the single biggest gap.
- The provider tool (shipped **noetl-tools 3.25.0 / noetl-cli 4.17.0**) covers
  **all 11** operation types the playbooks emit — folders, org/billing IAM,
  projects, billing link, service enable — for both plan and apply.
- **Out of scope for `kind: provider`, full stop: uploading YouTube videos.** The
  tool is resource-*management* (CRM v3 / Billing v1 / Service Usage v1). It can
  turn the YouTube Data API *on* for a project (`services.enable
  youtube.googleapis.com`); it **cannot** upload a video. Video upload is YouTube
  Data API v3 `videos.insert` — a data-plane API with a different auth model
  (3-legged OAuth user consent, not service-account ADC) and resumable-upload
  semantics. That belongs in a separate playbook/tool, not this one.
- **I cannot run a live `noetl provider plan` in this environment.** The installed
  `noetl` is **v2.17.0** (Python-era, no `provider` subcommand); the only built
  Rust binary in the tree is **v4.12.0** (predates even `Tool::Provider`
  dispatch). Running the real plan needs noetl-cli ≥4.17.0 built/installed, plus
  — for a *meaningful* diff against live Google state — an explicit read-only
  `auth:` credential I will **not** improvise. I produced the **dry-run plan by
  hand** below (the exact `would_call` shape the tool emits, zero network), and
  named precisely what's needed to run it for real.

---

## 1. What exists in shastara-org today

Repo: `/Volumes/X10/projects/shastaratech/gcp-org-playbooks` @ `3b88d7b`
("switch gcp playbooks to api operation specs"). Public, org id `561323743912`
(already in the repo — not a secret).

| Playbook | Models | State |
| --- | --- | --- |
| `automation/gcp_org/org_folders.yaml` | 5 standard folders (`00-shared`, `10-platform`, `20-media`, `30-websites`, `90-sandbox`) under the org | **Spec-emitter.** `plan`/`apply` both just print `folders.ensure` specs; `status` prints `folders.list`. |
| `automation/gcp_org/org_iam.yaml` | Org-level admin roles (organizationAdmin, folderAdmin, projectCreator, securityAdmin, serviceUsageAdmin) for users/groups | Spec-emitter → `organizations.iam.ensure_binding` per member×role; `status` → `get_policy`. |
| `automation/gcp_org/billing_iam.yaml` | `roles/billing.admin` on a billing account (ID injected at runtime, never committed) | Spec-emitter → `billingAccounts.iam.ensure_binding`; `status` → `get_policy`. |
| `automation/gcp_org/project_factory.yaml` | Generic project: create + place under folder + link billing + enable APIs | Spec-emitter → `projects.ensure` + `projects.billing.link` + `services.enable`×N; `status` → `projects.describe` + `services.list_enabled`. |
| `automation/gcp_org/youtube_publisher_project.yaml` | The concrete `shastaratech-youtube-prod` project under `20-media`, APIs `youtube,iam,serviceusage,cloudresourcemanager` | Spec-emitter (same shape as project_factory, hardcoded inputs). Prints "create OAuth consent screen + Desktop OAuth client manually in Console." |
| `automation/gcp_org/bootstrap_foundation.yaml` | Prints the recommended 4-step sequence | Doc-only echo. |

**The critical structural fact:** every one of these is
`tool: { kind: shell, cmds: [ ... cat <<EOF ... ] }`. They emit **text** — a
stream of JSON objects like:

```json
{ "provider":"google", "runtime":"noetl-provider-google",
  "service":"cloudresourcemanager.googleapis.com", "api_version":"v3",
  "action":"folders.ensure", "parent":"organizations/561323743912",
  "display_name":"20-media", "dry_run":"true" }
```

Nothing consumes that JSON. `apply` prints the same specs as `plan` — it does not
mutate anything, by design (the repo's own docs say actual mutation "should remain
blocked until the NoETL provider tool exists"). So today the repo is a
**design-complete, execution-empty** scaffold. The tool now exists; the wiring
does not.

**Complete:** the folder taxonomy, the IAM role list, the billing-IAM
no-commit-of-account-id discipline, the youtube project's inputs, the
public-safe spec shape. **Stub:** all execution (it's all `echo`). **Missing:**
the bridge from emitted spec → `kind: provider` step; any resolution of
`folders/by-display-name/X` → numeric folder id; org-policy; the YouTube
data-plane (upload) path.

---

## 2. Gap analysis — design need vs. tool capability (blunt)

### 2.1 What the tool covers (noetl-tools 3.25.0)

All 11 emitted operation types map 1:1 onto tool actions, and **all 11 are
apply-executable** in the shipped release (round-2 added GET-first idempotent
converge + bounded LRO for the `ensure`/`ensure_binding`/`enable`/`link` verbs;
round-4 added the `reconcile: report|enforce|adopt` policy; round-5 added the
`noetl provider plan/drift/orphans/adopt` CLI verbs + ownership fold):

| shastara-org emits | tool action | apply path in 3.25.0 |
| --- | --- | --- |
| `folders.list` | `google.cloudresourcemanager.folders.list` | read-only GET |
| `folders.ensure` | `…folders.ensure` | GET-first converge + LRO |
| `organizations.iam.get_policy` | `…organizations.iam.get_policy` | read-only |
| `organizations.iam.ensure_binding` | `…organizations.iam.ensure_binding` | getIamPolicy → merge → setIamPolicy (etag) |
| `projects.describe` | `…projects.describe` | read-only GET |
| `projects.ensure` | `…projects.ensure` | GET-first converge + LRO |
| `projects.billing.link` | `google.cloudbilling.projects.link` | idempotent PUT |
| `billingAccounts.iam.get_policy` | `…billing_accounts.iam.get_policy` | read-only |
| `billingAccounts.iam.ensure_binding` | `…billing_accounts.iam.ensure_binding` | getIamPolicy → merge → set (etag) |
| `services.list_enabled` | `google.serviceusage.services.list_enabled` | read-only GET |
| `services.enable` | `google.serviceusage.services.enable` | idempotent POST |

So on the **resource-management** axis, coverage is complete. The gaps are at the
edges.

### 2.2 What the tool does NOT cover — say it plainly

1. **YouTube video upload — OUT OF SCOPE, and not a small gap.** The whole point
   of the youtube publisher project is to *upload videos*. The provider tool
   cannot do that and should not be extended to. Uploading is **YouTube Data API
   v3** (`youtube.videos.insert`), which is:
   - a **data-plane** API, not resource-management — it's not CRM/Billing/
     ServiceUsage, the only three surfaces the tool speaks;
   - authenticated by **3-legged OAuth** (a channel owner consents; you act *as*
     that Google/YouTube account), **not** the service-account ADC the provider
     tool uses. A service account cannot own or post to a YouTube channel;
   - a **resumable multipart upload** with media bytes, quota cost ~1600
     units/upload, and its own error model.
   The provider tool's *only* YouTube involvement is `services.enable
   youtube.googleapis.com` — flipping the API on for the project. **Uploading is a
   separate NoETL playbook** (an `http`/OAuth tool step, or a purpose-built
   `youtube` tool kind), tracked separately. Do not conflate "enable the API" with
   "publish a video."

2. **OAuth consent screen + OAuth client creation — manual / out of scope.** The
   youtube_publisher playbook already says so ("create OAuth consent screen and
   Desktop OAuth client manually in Google Cloud Console"). These live in the API
   Console / IAP brand API (`iap.googleapis.com` OAuth brands + identity-aware
   proxy), none of which is in the tool's three APIs. This is a **manual Console
   step** and a prerequisite for the upload playbook, not for provisioning.

3. **Org policy (constraints) — not covered.** `orgpolicy.googleapis.com` is not
   one of the three supported services. If shastara-org wants org-level guardrails
   (restrict resource locations, disable service-account key creation, domain-
   restricted sharing), the tool can't set them today. Not in the current playbook
   design, but the highest-blast-radius thing you might reach for at org bootstrap
   — flagging so it's a conscious "later / manual" and not an assumed capability.

4. **`folders/by-display-name/<name>` parent resolution — a real integration
   seam.** The playbooks emit project parents as
   `parent: folders/by-display-name/20-media`. The Google API needs a **numeric**
   folder id (`folders/123456789`). In the round-1 code I can inspect locally
   (`repos/tools` @ 3.21.0, `src/tools/provider.rs:317,396`), the tool passes
   `parent` **verbatim** into the request — it does **not** resolve a
   `by-display-name` pseudo-parent. `folders.ensure` self-resolves display-name
   (it lists under the parent and matches), but `projects.ensure` under a folder
   needs that folder's real id. **Verify in 3.25.0 whether `projects.ensure`
   resolves `by-display-name`.** If it doesn't, the design *must* be two-phase:
   create folders first, capture their numeric ids from the tool result, then feed
   `parent: folders/<id>` into project creation. The dependency graph below is
   written that way regardless, so it's correct either way — but it changes
   whether one `noetl provider plan` can render the whole thing or needs the
   folder ids threaded through.

5. **Group existence / membership — not the tool's job.** `org_iam.yaml` prefers
   `group:gcp-org-admins@…`. The tool will `setIamPolicy` a group member fine, but
   it does not create the Google Group or manage membership (that's Workspace /
   Cloud Identity Groups API). Assumed pre-existing. Correct division; just noting
   it.

6. **No wiring exists (restating §1 as a gap).** The shastara-org playbooks don't
   call `kind: provider`. Phase B's first task is the bridge: rewrite the shell
   playbooks (or add sibling playbooks) so each emitted spec becomes a
   `kind: provider` step — the shape is exactly
   `repos/tools/examples/provider_gcp_org.yaml`. Until that lands, the tool and the
   design don't touch.

---

## 3. Design — the provisioning playbook set

### 3.1 Resource graph + dependency order

```
organizations/561323743912                     (pre-exists; you have it)
        │
        ├─(A) folders.ensure ×5   00-shared 10-platform 20-media 30-websites 90-sandbox
        │        └─ returns numeric folder ids  ─────────────┐
        │                                                     │
        ├─(B) organizations.iam.ensure_binding               │  (org-level; independent
        │        admins × {orgAdmin,folderAdmin,             │   of folders, but do AFTER
        │        projectCreator,securityAdmin,               │   so the taxonomy is real)
        │        serviceUsageAdmin}                           │
        │                                                     │
        ├─(C) billingAccounts.iam.ensure_binding             │  (needs billing acct id at
        │        billing-admins × roles/billing.admin        │   runtime; independent)
        │                                                     ▼
        └─(D) projects.ensure  shastaratech-youtube-prod  parent = folders/<20-media id>
                 │
                 ├─(E) projects.billing.link   → billingAccounts/<id>
                 │
                 └─(F) services.enable ×4   youtube, iam, serviceusage, cloudresourcemanager
                          (some APIs require billing linked first → E before F)

  ── out of provider scope, sequenced after ──
  (G) MANUAL: OAuth consent screen + Desktop OAuth client   (Console / IAP brand)
  (H) SEPARATE PLAYBOOK: youtube videos.insert upload        (OAuth data-plane; not this tool)
```

**Hard ordering:** A → D (project needs its folder id; see §2.2.4). E → F (billing
before APIs that require it). B and C are order-independent of A/D but should run
after A so grants land on a real hierarchy. G is a manual prerequisite for H. H is
a different thread entirely.

**Bootstrapping caveat (chicken-and-egg):** the identity *running* these
playbooks must already hold org-level create rights
(`resourcemanager.folderCreator`/`projectCreator` + `billing.admin`). Step B
grants rights to *other* admins; it does not bootstrap the runner's own access.
That first grant is done by an Org Admin out-of-band (Console or an existing
break-glass identity) — name it as a prerequisite, don't try to self-grant.

### 3.2 `stack:` scoping label

Use a single stack label for the whole foundation so ownership/drift/orphan
queries (`noetl provider drift/orphans`) scope to it and don't collide with any
other org the tool later manages:

```yaml
stack: shastaratech-org-foundation
```

The round-5 design keeps `stack` a free-form string, so this can later encode
`shastaratech/<folder>/<project>` hierarchy with no schema change if you want
finer scopes (e.g. a separate `shastaratech-youtube-prod` stack for the project's
own resources). Recommend starting with **one** foundation stack.

### 3.3 dry_run / reconcile / confirm-gating per step

- **Every step is `dry_run: "{{ workload.action != 'apply' }}"`** — the existing
  playbook convention. `action=plan` (default) → dry-run, no token minted, no
  network. `action=apply` → real call, **requires explicit `auth:`** (the tool
  refuses apply-mode with no `auth:` — no ambient ADC fallback).
- **`reconcile:` policy** (round-4) governs the mutating `ensure` steps:
  - `report` (the shipped **default**) — detect + report drift, change nothing.
    This is the "show me first" mode. **Behavior note:** because `report` is
    default, an unqualified `action=apply` will *not converge* — you must set
    `reconcile: enforce` on the ensure steps to actually create/patch. This is the
    one behavior-change footgun from round-4; the Phase B playbooks must set
    `reconcile: enforce` explicitly on A/B/C/D/E/F or nothing happens.
  - `enforce` — push desired → actual (GET-first idempotent; re-run = no-op).
  - `adopt` — accept live actual as new desired (GET-only, import/take-ownership).
    Confirm-gated: dry-run emits a field-diff + `plan_digest`; apply needs
    `confirm:<digest>`; blind or stale digest is **refused**.
- **Destroy verbs** (`folders.delete`, `projects.delete`, `services.disable`,
  `*.iam.remove_binding`) are **not** in this provisioning design and should stay
  out of it. They are confirm-gated (dry-run digest → apply `confirm:<digest>`,
  stale/blind refused, no wildcards) — reserved for a deliberate teardown thread.

### 3.4 Playbook shape (Phase B target — NOT written this round)

Two viable shapes; recommend the first:

- **(preferred) Rewrite each shell playbook's body into `kind: provider` steps**,
  keeping the same `workload` inputs and `action` switch. Model:
  `repos/tools/examples/provider_gcp_org.yaml`. One step per emitted spec; the
  folder step returns ids that later project steps reference via the shared cache.
- **(alt) `noetl provider plan/drift/adopt` CLI over the emitted spec stream** —
  keep the shell playbooks as spec generators and drive the tool from the CLI
  verbs. Heavier glue; only worth it if you want the shell playbooks to stay the
  source of truth. The fold/ownership CLI needs `--server` (EHDB eventlog tier) or
  `--facts-file`; for a greenfield org last-known-desired is empty so drift = all
  UNTRACKED (everything to create), which is fine and needs no server.

---

## 4. The PLAN (dry-run) — what would be created, resource by resource

**How this was produced:** I could not execute `noetl provider plan` here (§TL;DR
— no capable binary installed; a live diff needs a read-only `auth:` I won't
improvise). This table is the **exact `would_call` structure the tool emits in
plan mode** — `{method, url, body_shape}` with the credential never present —
derived from the shipped action→REST mapping. Running the real binary with these
inputs and `dry_run: true` produces this same output and makes **no** network
call. For a *live* plan that also shows which of these already exist, the tool
needs read-only GET (`folders.list`, `projects.describe`,
`services.list_enabled`) against Google, which needs explicit `auth:` — see §6.

Inputs assumed: `org_id=561323743912`, folder `20-media`, project
`shastaratech-youtube-prod`, billing account `<BILLING_ACCOUNT_ID>` (runtime),
admins `<ADMIN>` (runtime).

| # | Step | Method | URL (host + path) | Body shape (no secrets) |
| --- | --- | --- | --- | --- |
| A1 | folders.ensure 00-shared | POST | `cloudresourcemanager.googleapis.com/v3/folders` | `{parent:"organizations/561323743912", displayName:"00-shared"}` (GET-first: list under org, skip if present) |
| A2 | folders.ensure 10-platform | POST | `…/v3/folders` | `{parent:"organizations/561323743912", displayName:"10-platform"}` |
| A3 | folders.ensure 20-media | POST | `…/v3/folders` | `{parent:"organizations/561323743912", displayName:"20-media"}` |
| A4 | folders.ensure 30-websites | POST | `…/v3/folders` | `{parent:"organizations/561323743912", displayName:"30-websites"}` |
| A5 | folders.ensure 90-sandbox | POST | `…/v3/folders` | `{parent:"organizations/561323743912", displayName:"90-sandbox"}` |
| B* | org IAM ensure_binding (per admin × 5 roles) | POST | `…/v3/organizations/561323743912:setIamPolicy` | getIamPolicy → add `{member:"user:<ADMIN>", role:"roles/resourcemanager.organizationAdmin"}` (+folderAdmin, projectCreator, iam.securityAdmin, serviceusage.serviceUsageAdmin) with etag |
| C* | billing IAM ensure_binding (per admin) | POST | `cloudbilling.googleapis.com/v1/billingAccounts/<BILLING_ACCOUNT_ID>:setIamPolicy` | getIamPolicy → add `{member:"user:<ADMIN>", role:"roles/billing.admin"}` with etag |
| D | projects.ensure youtube-prod | POST | `cloudresourcemanager.googleapis.com/v3/projects` | `{projectId:"shastaratech-youtube-prod", displayName:"ShastaraTech YouTube Publisher", parent:"folders/<20-media id>"}` (GET-first) |
| E | projects.billing.link | PUT | `cloudbilling.googleapis.com/v1/projects/shastaratech-youtube-prod/billingInfo` | `{billingAccountName:"billingAccounts/<BILLING_ACCOUNT_ID>"}` |
| F1 | services.enable youtube | POST | `serviceusage.googleapis.com/v1/projects/shastaratech-youtube-prod/services/youtube.googleapis.com:enable` | `{}` |
| F2 | services.enable iam | POST | `…/services/iam.googleapis.com:enable` | `{}` |
| F3 | services.enable serviceusage | POST | `…/services/serviceusage.googleapis.com:enable` | `{}` |
| F4 | services.enable cloudresourcemanager | POST | `…/services/cloudresourcemanager.googleapis.com:enable` | `{}` |

Plan-mode result per step is `{provider:"google", action:…, dry_run:true,
changed:false, backend:"rest", would_call:{method,url,body_shape}, input:…}` — the
bearer token is never minted and never appears. The `<20-media id>` in D is the
seam from §2.2.4: it's a numeric id produced by A3 at apply time; in a pure
offline plan it stays symbolic.

Read-only status calls (not mutations, safe to run first once auth exists):
`folders.list?parent=organizations/561323743912`,
`GET /v3/projects/shastaratech-youtube-prod`,
`GET …/services?filter=state:ENABLED`.

---

## 5. Irreversible / high-blast-radius risks — what cannot be undone

1. **Project IDs are globally unique and non-reusable.**
   `shastaratech-youtube-prod` — if that id is already taken by *anyone* on Google
   Cloud, `projects.ensure` fails. If you create it and later delete it, the id
   goes into a ~30-day soft-delete and is then **permanently retired** — you can
   never recreate a project with that exact id. Choose the id deliberately.
2. **IAM `setIamPolicy` can lock admins out.** These are read-modify-write on the
   *entire* policy. The tool does getIamPolicy → merge → setIamPolicy with the
   etag (which mitigates blind overwrite), but a wrong role, a concurrent edit
   losing the etag race, or removing the wrong member can revoke org-admin access.
   At the org level that is a **support-ticket-to-Google** recovery. Keep at least
   one break-glass Org Admin identity outside the automation.
3. **Folder hierarchy moves are disruptive.** Folders can be deleted only when
   empty; moving a folder with live projects re-parents IAM inheritance and can
   silently change effective permissions. The 5-folder taxonomy is cheap to create
   but expensive to reorganize once projects and grants hang off it.
4. **Billing link → real charges.** `projects.billing.link` attaches a payment
   instrument; enabling APIs (F) on a billing-linked project can start metered
   cost immediately (some APIs have free tiers, some don't). Reversible (unlink /
   disable) but money may already have moved.
5. **API enablement is reversible but dependency-laden.** `services.enable` is
   safe and idempotent; `services.disable` (not in this design) can cascade-break
   anything using the API. Not irreversible, but not free.
6. **Org policy (if ever added, §2.2.3) is the sharpest edge** — an org policy
   constraint applies to the whole org subtree and can lock out legitimate
   operations org-wide. Explicitly *not* in scope here; named so it stays a
   conscious future decision.

Enabling an API, listing, describing, and get_policy are all **safe/reversible**.
The dangerous set is: project creation (id burn), any `setIamPolicy`, billing
link, and — outside this design — folder deletion and org policy.

---

## 6. What I need from you before Phase B can run

**Gate:** the wait phrase `implement provider tool` (per the brief, this same
phrase gates Phase B here). Phase B is *real Google infrastructure creation* — a
bigger step than the tool implementation was; treat the go-ahead accordingly.

**Tooling (blocker):**
- **Build/install noetl-cli ≥ 4.17.0.** The installed `noetl` is v2.17.0 and the
  built Rust binary is v4.12.0 — neither has `kind: provider` dispatch or the
  `noetl provider` verbs. This is a Rust build (libduckdb-sys is gated off by
  default now, so not the multi-hour compile, but still a build + a submodule
  checkout bump). Decide: build from `repos/cli` at the 4.17.0 tag, or install the
  released `noetl-v4.17.0-<platform>` binary.

**Credentials / permissions (I will NOT create or mint these):**
- An identity with **org-level rights** — `resourcemanager.folderCreator` +
  `resourcemanager.projectCreator` (or organizationAdmin) + `billing.admin` —
  resolvable as **either** Application Default Credentials **or** a NoETL keychain
  alias. Apply-mode steps need an explicit `auth:` alias; plan/dry-run needs none.
  Even a *live read-only plan* (to show what already exists) needs this auth for
  the GET calls. I stopped rather than improvising one.
- The **billing account id** — supplied at runtime via `--set
  billing_account_id=…`, never committed (the playbooks already enforce this).
- The **admin users/groups** to grant (and, if using groups, the groups must
  already exist in Cloud Identity — the tool won't create them).

**Decisions:**
- Confirm the **folder taxonomy** (the 5 standard folders) and whether any
  projects beyond `shastaratech-youtube-prod` are in this first pass.
- Confirm the **project id** `shastaratech-youtube-prod` is the intended,
  available id (irreversible — §5.1).
- Confirm **`stack: shastaratech-org-foundation`** as the ownership label (§3.2).
- Confirm the Phase B **playbook shape** — rewrite the shell playbooks into
  `kind: provider` steps (recommended) vs. drive via `noetl provider` CLI verbs
  (§3.4).
- Acknowledge the **`reconcile: enforce`** requirement — without it an `apply`
  reports drift and changes nothing (§3.3).
- Acknowledge that **YouTube video upload is a separate future thread** (§2.2.1),
  and that the **OAuth consent screen + client** are a manual Console prerequisite
  (§2.2.2).
- Verify (or have me verify at Phase B, read-only) whether 3.25.0's
  `projects.ensure` resolves `folders/by-display-name/X`; if not, Phase B is
  two-phase (folders first, thread ids) — §2.2.4.

---

## Issues observed

- **shastara-org playbooks are spec-emitters, not provider callers** — no wiring
  to `kind: provider` exists. Biggest missing piece; Phase B's first task.
- **No capable `noetl` binary in this environment** (2.17.0 installed / 4.12.0
  built). Can't run a live plan without a build.
- **`by-display-name` parent resolution unverified in 3.25.0** — round-1 code
  passes `parent` verbatim; if projects.ensure doesn't resolve it, provisioning is
  strictly two-phase.
- **`reconcile: report` default footgun** — an `apply` without `reconcile:
  enforce` silently changes nothing (round-4 behavior change).
- **The local `repos/tools`/`repos/cli` submodules are at round-1 (3.21.0 /
  4.12.0)**, behind the shipped 3.25.0/4.17.0 — I inspected round-1 code and
  reasoned about 3.25.0 capability from the memory record; a Phase B build syncs
  them.

## Manual escalation needed

- **Wait phrase `implement provider tool` not given** — Phase B (any GCP
  mutation, and even the noetl-cli build) is deferred.
- **Credentials are yours to provide** — org-admin ADC or keychain alias + billing
  account id + admin members. I minted nothing, requested nothing, improvised
  nothing.
- **OAuth consent screen + Desktop OAuth client** for the YouTube publisher are a
  **manual Console step** — outside the provider tool and outside NoETL entirely.
- **YouTube video upload** is a **separate playbook/tool** (OAuth data-plane) — not
  `kind: provider`; scope it as its own thread when you're ready.
- **Org policy**, if wanted at bootstrap, is **not covered** by the tool — manual
  or a future action.

---
**Confirmation (Phase A complete, Phase B gated):** inspected all 6 shastara-org
playbooks + the runtime-design doc + the shipped provider-tool capability;
produced the resource graph, dependency order, stack label, per-step dry_run/
reconcile design, a hand-rendered dry-run plan (zero network), and the
irreversible-risk list. **No GCP reads or writes, no `gcloud`, no builds, no
kind/prod actions.** No unrelated dirty state touched — only the two new files in
`handoffs/active/2026-07-14-shastara-org-gcp-provision/`. Report placed in a new
thread to avoid clobbering the provider-tool implementation record.
