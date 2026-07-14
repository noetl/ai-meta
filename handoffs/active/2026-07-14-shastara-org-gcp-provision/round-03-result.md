---
thread: 2026-07-14-shastara-org-gcp-provision
round: 3
from: claude
to: user
created: 2026-07-14T01:20:00Z
in_reply_to: round-03-prompt.md
status: complete
---

# Round 3 — design against the real org: bootstrap, reconciliation, plan, risks

Org `561323743912` now exists. This round confirms the IAM bootstrap gap
read-only, reconciles the playbooks against the real 5-folder / 10-project target,
renders the full dependency-ordered dry-run plan, gives the YouTube scope verdict,
and lists the irreversible risks. **Still Phase A — no remote writes, no GCP
mutations, no builds. Only read-only `gcloud get-iam-policy`/`list`/`describe` and
these two round-03 files.**

**Public-repo hygiene (your instruction):** ai-meta is public and these files are
committed. The **billing account ID and personal emails are masked** here —
`<BILLING_ACCOUNT_ID>`, "the runner identity", "target admin A/B", "the root
account". The org ID `561323743912` is kept (already public in the shastara repo).
Feed the real billing ID and emails only as runtime `--set` values, never into
git. *(Note: rounds 01–02 quoted a few identity emails verbatim from `gcloud auth`
output before this instruction; per the append-only handoff rule I have not
rewritten them. If you want those scrubbed, that's a deliberate history edit —
say so. The billing ID has never been committed in any round.)*

---

## 1. The bootstrap chicken-and-egg — confirmed read-only

**Verified now (read-only):**

- The **runner identity** (the active gcloud ADC, a `@cybx.io` account) —
  `gcloud organizations list` shows it can see only `adiona.org` (103794563683)
  and `cyberionix.com` (712221118891). **It does not see `561323743912`.**
- `gcloud organizations describe 561323743912` → **permission denied**.
- `gcloud organizations get-iam-policy 561323743912` → **permission denied**
  (`does not have permission to access organizations instance
  [561323743912:getIamPolicy]`).
- **Target admin B** (the `@gmail.com` target admin) — same: sees only
  `adiona.org`, cannot describe `561323743912`.

So **neither target admin has any role on the new org yet.** Only the **root
account** (the shastaratech Cloud Identity super admin, which by default holds
`roles/resourcemanager.organizationAdmin` on org creation, and which has **no
credential on this machine**) can currently touch it.

**The chicken-and-egg, stated plainly:**

- **Which identity will the playbooks run as?** Recommend **the runner identity**
  (the active `@cybx.io` ADC) — it's already the machine's default credential, so
  the provider tool's apply-mode `auth:` alias can resolve to it. (Any single
  identity works; pick one and grant it the full bundle.)
- **What it currently has on `561323743912`:** *nothing.* No view, no create, no
  IAM read.
- **Minimum it needs** to run the whole graph (folders + projects + billing + APIs
  + IAM):

  | Scope | Role | For |
  | --- | --- | --- |
  | org `561323743912` | `roles/resourcemanager.folderCreator` (or `folderAdmin`) | create the 5 folders |
  | org `561323743912` | `roles/resourcemanager.projectCreator` | create the 10 projects |
  | org `561323743912` | `roles/resourcemanager.organizationAdmin` | set org-level IAM (org_iam.yaml) + move projects into folders |
  | billing `<BILLING_ACCOUNT_ID>` | `roles/billing.admin` | link billing + set billing IAM |
  | (per project, after create) | `roles/serviceusage.serviceUsageAdmin` | enable APIs (inherited from org grant if org-level) |

  Granting the org-level bundle at the **org** node makes it inherit down to every
  folder/project, so a single set of org grants + `billing.admin` on the billing
  account covers everything.

- **What the human must do FIRST (no playbook can bootstrap this):** signed in as
  **the root account** (`shastaratech` super admin), grant the runner identity the
  bundle above — via Cloud Console (IAM & Admin → grant at org + billing) or
  `gcloud organizations add-iam-policy-binding 561323743912 --member=user:<runner>
  --role=...` and `gcloud billing accounts add-iam-policy-binding
  <BILLING_ACCOUNT_ID> ...`. **I did not and will not perform this grant.**

  Only after that first manual grant can the playbooks run as the runner identity
  — including `org_iam.yaml` to grant the *second* admin. That first org-level
  binding is the irreducible human step. (Equivalently: the human just grants
  *both* target admins via Console and you skip `org_iam.yaml` for the humans
  entirely — but at least one org-admin grant is manual, by definition.)

---

## 2. Reconciliation — playbooks vs. real desired state

Repo `gcp-org-playbooks` @ `0349ad6`/`3b88d7b`. Checked against the 5-folder /
10-project target + real ORG_ID + masked billing.

| Aspect | State |
| --- | --- |
| **ORG_ID `561323743912`** | ✅ Baked as default across all playbooks + docs. Now a **real, verified** org (round 2 said it was unverified; that's resolved). |
| **Billing ID** | ✅ Kept out of git; runtime `--set billing_account_id=…`. Preserve — do **not** bake it in. |
| **Emails** | ✅ Kept out of git; runtime `--set admin_users=…`. Preserve. |
| **5 folders** | ✅ `org_folders.yaml` creates exactly `00-shared 10-platform 20-media 30-websites 90-sandbox` — matches the target. |
| **10 projects → folder mapping** | ⚠️ **Not declared anywhere as data.** `project_factory.yaml` is a **generic one-project-at-a-time** template (`--set project_id=… folder_name=… apis=…`). Only `shastaratech-youtube-prod` has a dedicated playbook (`youtube_publisher_project.yaml`, hardcoded to `20-media`). The other **9 projects and their folder placement live only in this handoff** — there is no playbook/data file encoding the full folder→project graph. **Gap:** to provision all 10 you either invoke `project_factory.yaml` 10× with per-project `--set`, or add a declarative graph (a per-project list). Recommend the latter for a reviewable, idempotent full-graph run. |
| **Per-project API sets** | ⚠️ Only `youtube-prod` has APIs specified (`youtube,iam,serviceusage,cloudresourcemanager`). The other 9 have **no declared API set** — undecided. Must be specified before their `services.enable` steps mean anything (e.g. noetl-prod likely needs compute/container/sqladmin/etc.; web-* needs run/firebase/etc.). Flag for decision. |
| **Org IAM roles** | `org_iam.yaml` grants a sensible bundle (organizationAdmin, folderAdmin, projectCreator, iam.securityAdmin, serviceusage.serviceUsageAdmin). Matches the runner-identity need in §1 — but see the chicken-and-egg (it can't grant the runner its *own* first role). |
| **Execution wiring** | ❌ Still `kind: shell` spec-emitters (round-1 finding, unchanged) — they `echo` JSON, they don't call `kind: provider`. No wiring exists. Phase B's first task. |
| **`by-display-name` parent** | ⚠️ Projects declare `parent: folders/by-display-name/<name>` (round-1 seam). The numeric folder IDs don't exist until the folders are created; verify the tool resolves the pseudo-parent, else provisioning is strictly two-phase (folders → capture IDs → projects). |

**Net:** folders + the youtube project are fully modelled; the **other 9 projects,
their folder placement, and their per-project API sets are not declared** and are
the real reconciliation gap. The graph is *known* (this handoff) but not yet
*encoded* as playbook data.

---

## 3. Dry-run PLAN — full desired state, dependency order

**How produced / limits (unchanged from rounds 1–2):** I **cannot run
`noetl provider plan` here** — installed `noetl` is v2.17.0, the only built Rust
binary is v4.12.0, neither has the provider path; running it for real needs
noetl-cli ≥4.17.0 built/installed. A *live* plan that shows what already exists
also needs read-only GET against Google, which needs an explicit `auth:`
credential (the runner identity's ADC/keychain alias) — **I will not improvise
one**. Below is the exact `would_call` shape the tool emits in dry-run (method +
URL + body-shape, **no token, no network**), for the whole graph.

### Phase 0 — HUMAN prerequisite (not a playbook)
Root account grants the runner identity: org bundle on `561323743912` +
`roles/billing.admin` on `<BILLING_ACCOUNT_ID>` (§1). Nothing below runs until
this lands.

### Phase 1 — folders (parent = org). `reconcile: enforce`, GET-first idempotent.
| Resource | Method | URL | Body |
| --- | --- | --- | --- |
| 00-shared | POST | `cloudresourcemanager.googleapis.com/v3/folders` | `{parent:"organizations/561323743912", displayName:"00-shared"}` |
| 10-platform | POST | `…/v3/folders` | `{…, displayName:"10-platform"}` |
| 20-media | POST | `…/v3/folders` | `{…, displayName:"20-media"}` |
| 30-websites | POST | `…/v3/folders` | `{…, displayName:"30-websites"}` |
| 90-sandbox | POST | `…/v3/folders` | `{…, displayName:"90-sandbox"}` |

Each folder-create returns an LRO → a **numeric folder ID**; those IDs feed Phase 2
`parent`. In pure offline dry-run they stay symbolic (`folders/<20-media id>`).

### Phase 2 — projects (parent = folder id from Phase 1). `reconcile: enforce`, GET-first.
| Project ID | Folder | Method | URL | Body |
| --- | --- | --- | --- | --- |
| **shastaratech-youtube-prod** *(priority)* | 20-media | POST | `…/v3/projects` | `{projectId:"shastaratech-youtube-prod", displayName:…, parent:"folders/<20-media id>"}` |
| shastaratech-billing-admin | 00-shared | POST | `…/v3/projects` | `{projectId:"shastaratech-billing-admin", parent:"folders/<00-shared id>"}` |
| shastaratech-dns-prod | 00-shared | POST | `…/v3/projects` | `{projectId:"shastaratech-dns-prod", parent:"folders/<00-shared id>"}` |
| shastaratech-observability-prod | 00-shared | POST | `…/v3/projects` | `{…, parent:"folders/<00-shared id>"}` |
| shastaratech-noetl-dev | 10-platform | POST | `…/v3/projects` | `{…, parent:"folders/<10-platform id>"}` |
| shastaratech-noetl-prod | 10-platform | POST | `…/v3/projects` | `{…, parent:"folders/<10-platform id>"}` |
| shastaratech-ai-lab | 10-platform | POST | `…/v3/projects` | `{…, parent:"folders/<10-platform id>"}` |
| shastaratech-web-dev | 30-websites | POST | `…/v3/projects` | `{…, parent:"folders/<30-websites id>"}` |
| shastaratech-web-prod | 30-websites | POST | `…/v3/projects` | `{…, parent:"folders/<30-websites id>"}` |
| shastaratech-sandbox | 90-sandbox | POST | `…/v3/projects` | `{…, parent:"folders/<90-sandbox id>"}` |

Each project-create is an LRO. GET-first: `GET /v3/projects/<id>` → skip if present.

### Phase 3 — billing link (each project). Idempotent PUT.
For each of the 10 project IDs:
`PUT cloudbilling.googleapis.com/v1/projects/<project_id>/billingInfo`
body `{billingAccountName:"billingAccounts/<BILLING_ACCOUNT_ID>"}`.
(Order note: link billing before enabling any billing-required API.)

### Phase 4 — API enablement (Service Usage). Idempotent POST.
- **shastaratech-youtube-prod** (specified): `POST
  serviceusage.googleapis.com/v1/projects/shastaratech-youtube-prod/services/<svc>:enable`
  for `youtube.googleapis.com`, `iam.googleapis.com`, `serviceusage.googleapis.com`,
  `cloudresourcemanager.googleapis.com`.
- **Other 9 projects:** API sets **undeclared** — needs your input (§2). Plan can't
  render them until specified. Flag, not bodge.

### Phase 5 — IAM. Read-modify-write with etag.
- **Org IAM** (`org_iam.yaml`): for each target admin × role bundle →
  `POST …/v3/organizations/561323743912:setIamPolicy` (getIamPolicy → merge → set
  with etag). **Constraint:** the runner's *own* first org role can't come from
  here (§1) — human-granted.
- **Billing IAM** (`billing_iam.yaml`): admins × `roles/billing.admin` →
  `POST …/v1/billingAccounts/<BILLING_ACCOUNT_ID>:setIamPolicy` (getIamPolicy →
  merge → set).
- **Project-level IAM** (per-project owners/editors): **no tool action exists** —
  the tool has org & billing IAM `ensure_binding` but **no
  `projects.iam.ensure_binding`** (round-2 gap, still open). If you need per-project
  role grants, that's a small Phase-B tool addition.

**Plan-mode result per step:** `{provider:"google", action:…, dry_run:true,
changed:false, backend:"rest", would_call:{method,url,body_shape}, input:…}` — the
bearer token is never minted, no network call. **`reconcile: enforce` reminder:**
without it, an `apply` reports drift and changes nothing (round-4 default is
`report`).

---

## 4. YouTube scope verdict

- **IN scope for `kind: provider`:** creating `shastaratech-youtube-prod`, linking
  billing, and `services.enable youtube.googleapis.com`. That's Cloud Resource
  Manager v3 + Cloud Billing v1 + Service Usage v1 — the tool's exact wheelhouse.
  It stands the project up and turns the API on.
- **OUT of scope — uploading videos.** That is **YouTube Data API v3**
  (`youtube.videos.insert`) — content publishing, not infrastructure. Different in
  every relevant way: it's a **data-plane** API (not CRM/Billing/ServiceUsage);
  it authenticates via **3-legged OAuth** where a human channel owner consents and
  you act *as* that YouTube account (a service-account ADC **cannot** own or post
  to a channel); it's a **resumable media upload** with per-video quota cost. The
  provider tool has no verb for it and shouldn't grow one.
- **What carries the upload instead:** a **separate NoETL playbook** — either an
  `http` tool step doing the OAuth2 user-consent flow + resumable upload, or a
  purpose-built `youtube` tool kind. Its own thread when you're ready. **Also
  manual and prerequisite to it:** the **OAuth consent screen + OAuth client** for
  the project (Console / IAP brand — not in the tool's three APIs). Don't bodge
  either into the provisioning path.

---

## 5. Irreversibility / high-blast-radius risks — the section to read

1. **Project IDs are globally unique and NEVER reusable.** You are minting **10**
   of them. A typo — `shastaratech-noetl-prd`, `shataratech-web-prod` — creates a
   permanent project with the wrong ID; deleting it soft-deletes for ~30 days then
   **permanently retires the ID** (nobody, ever, can reuse it). **Triple-check all
   10 IDs before apply.** Especially the `-prod` ones you'll build real things on.
2. **`setIamPolicy` at org/billing can lock admins out.** These are whole-policy
   read-modify-write. The tool uses getIamPolicy→merge→set-with-etag (mitigates
   blind overwrite), but a wrong role, a lost etag race, or removing the wrong
   member can revoke org-admin. At the org level, recovery is a **Google support
   ticket**. **Keep the root account (`shastaratech` super admin) as untouched
   break-glass — never manage it via the automation.**
3. **Folder deletion / re-parenting.** A folder deletes only when empty; moving a
   folder or project changes **inherited IAM** silently. The 5-folder taxonomy is
   cheap to create, expensive to reorganize once 10 projects + grants hang off it.
   Get the folder→project placement right the first time.
4. **Billing detach / link.** Linking starts metered cost the moment a billing-
   required API is enabled on a project. **Detaching billing** from a project can
   **shut down resources and, after a grace period, delete data** (e.g. Cloud SQL,
   GCE disks). Reversible in principle, destructive in practice.
5. **API disable cascades.** `services.enable` is safe/idempotent;
   `services.disable` (not in this design) can cascade-break dependents. Not
   irreversible, not free.
6. **Org policy — not in scope, sharpest edge if ever added.** An org policy
   constraint applies org-wide and can lock out legitimate operations across the
   whole subtree. Explicitly out of this design; named so it stays a conscious
   decision.

**Safe/reversible:** folder/project/service *listing* and *describe*, `get_policy`,
`services.enable`. **Dangerous:** the 10 project-ID mints, any `setIamPolicy`,
billing link/detach, folder deletion, org policy.

---

## 6. The existing `shastara` project — flagged, NOT planned

You noted the existing `shastara` project (the Gmail-era standalone project, e.g.
the auto-generated `project-83c78291-…`) should be **kept as sandbox or cleanly
deleted**. Two options, both **deliberate, gated, human decisions** — I planned
**neither**:

- **Keep as sandbox:** `projects.move` it under `90-sandbox` (parent change). This
  is a **mutation** (re-parents IAM inheritance) — a Phase-B step, not silent, and
  only meaningful once the folder exists and the runner has org rights over both
  the project and the folder.
- **Delete cleanly:** `projects.delete` — **destructive and confirm-gated** in the
  tool (dry-run emits a `plan_digest`; apply needs `confirm:<digest>`; blind/stale
  refused; no wildcards). Soft-deletes ~30 days then permanent. **I did not and
  will not plan or run a delete.** It's a standalone confirm-gated teardown you
  trigger explicitly.

Recommendation: **keep it, move it to `90-sandbox`** — deletion buys nothing and
adds irreversible risk. But your call.

---

## What I need from you (before Phase B)

1. **The human first-grant (§1):** root account grants the runner identity the org
   bundle + `billing.admin`. Until this lands, no org-level playbook can run. This
   is on you / the root account — not automatable.
2. **Pick the runner identity** (recommend the active `@cybx.io` ADC) and how its
   `auth:` resolves for apply mode (ADC or a keychain alias).
3. **Declare the 9 non-youtube projects as data** (the folder→project graph) +
   **their per-project API sets** (§2) — undecided today.
4. **Confirm all 10 project IDs are correct** (irreversible — §5.1).
5. **Decide the existing `shastara` project** — move-to-sandbox (recommended) vs.
   confirm-gated delete (§6).
6. **Accept the tool gaps** for a full run: `by-display-name` parent resolution
   (verify in 3.25.0, else two-phase); no `projects.iam.ensure_binding` (add if you
   need per-project role grants).
7. **Tooling:** build/install **noetl-cli ≥4.17.0** (installed 2.17.0 / built
   4.12.0 can't run the provider path).
8. **Then** the wait phrase `implement provider tool` for Phase B.

---

## Issues observed

- **Runner + both target admins have zero access to `561323743912`** (verified
  read-only) — first org grant is a hard human step.
- **9 of 10 projects and all non-youtube API sets are undeclared** — the full graph
  isn't encoded as playbook data yet.
- **Playbooks still `kind: shell` spec-emitters** — no `kind: provider` wiring
  (round-1 finding).
- **Tool gaps for a full run:** `by-display-name` parent resolution unverified in
  3.25.0; no `projects.iam.ensure_binding`.
- **No capable `noetl` binary here** — can't run a live plan without a build.
- **Public-repo hygiene:** billing ID + emails masked in this round; rounds 01–02
  quoted a few emails pre-instruction and are left append-only (billing ID never
  committed).

## Manual escalation needed

- **First org-level IAM grant** (root account → runner identity) — human only, no
  API/playbook can bootstrap it.
- **OAuth consent screen + client** for the youtube project — manual Console step.
- **YouTube video upload** — separate playbook/tool (OAuth data-plane), out of
  `kind: provider`.
- **Existing `shastara` project delete**, if you choose it — deliberate confirm-
  gated destroy, your trigger.
- Wait phrase `implement provider tool` not given; no Phase B, no builds, no GCP
  writes. This round: read-only `gcloud` + two round-03 files only.

---
**Confirmation (round 3 complete):** verified read-only that the runner identity
and both target admins have no access to org `561323743912` (only adiona.org +
cyberionix.com visible); stated the human first-grant prerequisite + minimum role
bundle; reconciled playbooks (folders + youtube modelled; 9 projects + API sets
undeclared; still shell spec-emitters); rendered the full dependency-ordered
dry-run plan (folders → projects → billing → APIs → IAM) with no network; gave the
YouTube in/out scope verdict; listed the irreversible risks; flagged the existing
`shastara` project as a gated human decision (recommend move-to-sandbox, did not
plan a delete). Billing ID + emails masked for the public repo. No GCP state
created or modified; no active-config change.
