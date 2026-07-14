---
thread: 2026-07-14-shastara-org-gcp-provision
round: 6
from: claude
to: user
created: 2026-07-14T04:10:00Z
in_reply_to: round-06-prompt.md
status: complete
---

# Round 6 — Phase A FINAL: two existing projects incorporated via adopt

This closes Phase A. Ground truth is fully verified; the two pre-existing projects
are folded into the design through the `adopt` (Untracked → Owned) path **without
recreate**, and their placement/deletion is laid out as explicit, gated,
non-destructive-by-default options. **No remote writes: read-only `describe` /
`getIamPolicy` with the ADC token (never printed), a local no-network guard demo,
and these two round-06 files only.**

**Public-repo hygiene:** billing ID + owner email masked (`<BILLING_ACCOUNT_ID>`,
"the shastaratech owner account"). Org/project IDs are non-sensitive identifiers
(kept). ADC token never echoed or committed.

---

## 0. Verified ground truth

| Item | Value | Verified |
| --- | --- | --- |
| ADC identity | shastaratech owner account (`@gmail.com`) | ✅ tokeninfo, cloud-platform scope; sees **1 org** |
| Org | `561323743912` = shastaratech-org, ACTIVE | ✅ v3 search (count=1) |
| Billing | `<BILLING_ACCOUNT_ID>` open, parent = org | ✅ describe |
| Owner roles | organizationAdmin, projectCreator, projectMover, serviceUsageAdmin, billing.admin | ✅ org getIamPolicy |
| Quota/bootstrap project | `shastara` (crm/serviceusage/cloudbilling enabled) | per your report |
| **`shastara`** | `projects/1018756743824`, **parent NONE (orphan, outside org)**, ACTIVE | ✅ describe |
| **`My First Project`** | `project-83c78291-16c1-42f9-93b` / `projects/401992377820`, parent `organizations/561323743912` (**root, no folder**), ACTIVE | ✅ describe |

---

## 1. The two existing projects — how the tool sees them, and the adopt path

### 1a. Ownership-model classification (the dogfood moment)

Relative to the `shastaratech-org-foundation` stack's **declared desired** (the 5
folders + 10 target projects), neither existing project is in the desired set and
neither has a `provider_fact` yet. So under the round-3/4 drift model
(`compute_drift` → InSync / Missing / Modified / **Untracked** / NotManaged;
`detect_orphans_scoped` → owned-but-no-longer-declared):

- **`noetl provider drift`** would classify **both** `shastara` and
  `project-83c78291…` as **Untracked** — they exist live, but the desired state
  doesn't declare them and the ownership fold doesn't own them.
- **`noetl provider orphans`** would list **neither** — an *orphan* is a resource
  the stack **once owned** (has a `provider_fact`) but the desired set no longer
  declares. These two were never owned by the tool, so they're Untracked, **not**
  orphans. (Worth stating precisely, since the words are easy to conflate: orphan =
  "we owned it, you stopped declaring it"; untracked = "it exists, we never owned
  it.")

### 1b. `adopt` — bring them under management WITHOUT recreate

`noetl provider adopt` is exactly the round-4 Untracked → Owned verb: it **GETs the
live project** and writes a `provider_fact` (`verb:"adopt"`, `outcome:"adopted"`,
`import:true`) recording the live actual as the new desired — **no create, no
mutation of the resource itself** (round-4 built adopt as structurally read-only:
`run_adopt` reaches only `resolve_actual` → GET, never a write path). It is
**confirm-gated** identically to destroy: dry-run emits a field-by-field diff +
`plan_digest`; apply needs `confirm:<digest>`; blind apply and stale digest are
both **refused, nothing written**.

Dry-run adopt (no network mutation) for each:

```
adopt shastara (dry-run)
  urn        : google/cloudresourcemanager/project/shastara
  actual     : {projectId:"shastara", parent:<none>, state:ACTIVE}
  desired←actual (import:true)
  plan_digest: sha256(urn|present|parent=none|state=ACTIVE|…)
  -> apply needs confirm:<digest>; no resource mutation, writes ownership fact only

adopt project-83c78291-16c1-42f9-93b (dry-run)
  urn        : google/cloudresourcemanager/project/project-83c78291-16c1-42f9-93b
  actual     : {parent:"organizations/561323743912", state:ACTIVE, displayName:"My First Project"}
  desired←actual (import:true)
  plan_digest: sha256(...)
  -> apply needs confirm:<digest>; ownership fact only, no recreate
```

**Key distinction — adopt ≠ conform.** Adopt makes the tool *own and track* the
project as-is; it does **not** move it into a folder or change it. Reaching the
target structure is a **second, deliberate** step (`projects.move`, a mutation) if
you want them in folders. So the flow per project is: **adopt (track, gated, no
mutation) → then optionally move/delete (mutation, separately gated)**. This is the
"incorporate rather than destroy-and-recreate" capability you asked for: the
existing project keeps its ID, its billing, its history; the tool just starts
managing it.

### 1c. `shastara` (orphan + ADC quota project) — tradeoffs, no destructive default

`shastara` is outside the org (no parent), not governed by org policy, and — the
irony worth flagging — **it is the ADC quota project**, so it is **load-bearing for
the very API calls that build the org**. Consequences:

- **Deleting or moving it mid-run can break the run.** Quota/billing attribution
  for the provisioning calls routes through it. **Do not touch `shastara` during
  the bootstrap.** If you later delete/repurpose it, **first repoint the ADC quota
  project** (`gcloud auth application-default set-quota-project <a-real-project>`,
  e.g. `shastaratech-billing-admin` or a dedicated ops project) so the tool's own
  API path doesn't lose its quota project.
- **Options (your call — I plan none destructively):**
  1. **Leave as deliberate bootstrap/quota project** (outside the org). Simplest,
     zero risk during bootstrap. Downside: an ungoverned orphan lingers.
  2. **Adopt → then `projects.move` into `90-sandbox`** (your stated preference
     "keep shastara as sandbox"). This brings it under the org + a folder + org
     policy. It's an orphan→org move (`projects.move` with parent change) — a
     mutation; do it **after** the org exists and **after** repointing quota if
     you also stop using it for quota. Moving alone doesn't break quota attribution.
  3. **Delete + recreate cleanly** — **not clean** (see §5: the ID `shastara` is
     never reusable after delete). Confirm-gated destroy, human-triggered, never
     silent. I did **not** plan it.

### 1d. `My First Project` — inside org, no folder

The auto-created default project, under org root. Options:

- **Adopt → `projects.move` into a folder.** Which folder is a decision — if it's
  genuinely disposable it doesn't belong in the deliberate taxonomy; if you want to
  keep it, `90-sandbox` is the natural home. 
- **Delete** — confirm-gated destroy, human-triggered, never silent; ID
  `project-83c78291-16c1-42f9-93b` never reusable (irrelevant here since it's
  auto-generated, but the rule holds).
- **Recommendation:** adopt it for visibility, then either move to `90-sandbox` or
  gated-delete — your call. Not planned destructively.

---

## 2. Reconciled design (unchanged core + the two existing projects)

- Org / billing / folders / 10-project graph / stack label / guard — as rounds
  3–5 (all verified). The **two existing projects are additions to the model**:
  Untracked today → `adopt` to Owned → optional move into `90-sandbox`.
- Carried gaps (unchanged): 9 non-youtube projects + their API sets **undeclared**;
  playbooks still `kind: shell` spec-emitters; `by-display-name` parent resolution
  unverified in 3.25.0; no `projects.iam.ensure_binding`.

---

## 3. Dry-run PLAN — full desired state, dependency order (guarded)

`would_call` shape (method + URL + body-shape; no token, no network). Guard block
on every write-capable step. **`shastara` is explicitly excluded from all
mutating steps during bootstrap** (quota-project protection).

- **Phase 0 — guard pre-flight** (verified live in §0/round-5): org search → 1
  org; org display == shastaratech-org; billing open + parent == org. HARD FAIL
  halts.
- **Phase 1 — folders** `POST crm/v3/folders`
  `{parent:"organizations/561323743912", displayName:"<5 folders>"}`; GET-first;
  ids → Phase 2.
- **Phase 2 — projects** `POST crm/v3/projects` `{projectId:"<id>", parent:"folders/<id>"}`
  ×10 (new projects only; youtube-prod → `20-media` first). GET-first.
- **Phase 2b — ADOPT existing** (Untracked → Owned, GET-only, confirm-gated):
  `adopt shastara`, `adopt project-83c78291-…`. No recreate. *(Placement moves are
  Phase 6, separate + gated.)*
- **Phase 3 — billing link** `PUT cloudbilling/v1/projects/<id>/billingInfo`
  `{billingAccountName:"billingAccounts/<BILLING_ACCOUNT_ID>"}` ×10 new projects.
- **Phase 4 — API enable** `POST serviceusage/v1/projects/<id>/services/<svc>:enable`
  — youtube-prod: youtube/iam/serviceusage/cloudresourcemanager. **Other 9:
  undeclared — needs input.**
- **Phase 5 — IAM** — org IAM (admins × role bundle → org `:setIamPolicy`); billing
  IAM (admins × billing.admin → billing `:setIamPolicy`); project IAM: no tool
  action (Phase-B add if needed).
- **Phase 6 — placement of adopted projects** (optional, deliberate, gated):
  `projects.move shastara → folders/<90-sandbox id>` (after quota repoint) and/or
  `project-83c78291-… → folders/<chosen>`. Or gated-delete. **Never silent.**

`reconcile: enforce` required for converge. `stack: shastaratech-org-foundation`.

---

## 4. Wrong-org guard — proof (both layers, from round 5, still valid)

- **LIVE:** the acting identity gets **HTTP 403** on `getIamPolicy` for adiona.org
  (103794563683) and cyberionix.com (712221118891) — it cannot reach them at all.
- **OFFLINE:** the tool guard refuses a wrong `--set org_id=103794563683 /
  712221118891` **before any request is built, no network** (demonstrated
  decision-logic, round 4). Retained as defense-in-depth + load-bearing if the
  acting identity ever changes (e.g. the future dedicated SA).

Blast radius is eliminated at the identity **and** guarded in the tool.

---

## 5. Irreversibility / high-blast-radius risks

1. **Project IDs are globally unique and NEVER reusable — even after deletion.**
   Deletion is a ~30-day **soft-delete**, then permanent; the **ID is burned
   forever** regardless. So **"delete/recreate cleanly" is NOT clean for IDs** — if
   you delete `shastara`, you can never recreate a project with the ID `shastara`.
   Same for all 10 target IDs on any typo. This is the single most important line
   in this section: pick the 10 IDs deliberately and don't plan a delete-recreate
   of any ID you want to keep.
2. **`shastara` is the ADC quota project → load-bearing during bootstrap.**
   Deleting/moving it mid-run can break the provisioning calls. Repoint quota
   first if you ever retire it.
3. **Org/billing `setIamPolicy` lockout** — whole-policy read-modify-write; wrong
   role/lost-etag can revoke org-admin → Google support ticket. Keep the owner
   account as untouched break-glass.
4. **Folder deletion / re-parenting** — deletes only when empty; moves silently
   change inherited IAM.
5. **Billing detach** — can shut down resources + delete data after grace; link
   starts metered cost on API enable.
6. **Wrong-ORG writes** — eliminated at identity (403) + guarded; re-arms if the
   acting identity changes.
7. **Org policy** — out of scope; org-wide blast radius if ever added.

Safe/reversible: list/describe, get_policy, `services.enable`, **adopt** (GET-only,
writes an ownership fact, mutates no cloud resource). Dangerous: 10 ID mints, any
`setIamPolicy`, billing link/detach, folder deletion, project delete, `shastara`
touch during bootstrap.

---

## 6. YouTube scope verdict (unchanged)

- **IN scope for `kind: provider`:** create `shastaratech-youtube-prod`, link
  billing, `services.enable youtube.googleapis.com` (CRM v3 + Billing v1 + Service
  Usage v1).
- **OUT of scope — uploading videos:** YouTube Data API v3 `videos.insert` —
  content publishing, data-plane, 3-legged OAuth (a human channel owner consents;
  a service-account/ADC cannot own or post to a channel), resumable upload with
  per-video quota. **Carried by** a separate NoETL playbook (`http`+OAuth2 or a
  dedicated `youtube` tool). **Manual prerequisite:** OAuth consent screen + client
  (Console/IAP brand). The channel-owner OAuth identity ≠ the provisioning ADC.

---

## 7. What remains before Phase B

1. **Declare the 9 non-youtube projects as data** + **per-project API sets**.
2. **Confirm all 10 project IDs** (irreversible — §5.1).
3. **Decide the two existing projects:** `shastara` (leave-as-bootstrap /
   adopt+move-to-sandbox / gated-delete) and `My First Project` (adopt+move /
   gated-delete). If moving `shastara`, plan the **ADC quota repoint** first.
4. **Phase-B tool additions:** `guard:` block + `organizations.get` (Layer C) +
   guard unit tests; verify `by-display-name` parent resolution in 3.25.0;
   `projects.iam.ensure_binding` if per-project grants needed. (Adopt already
   exists — round 4.)
5. **Build/install noetl-cli ≥4.17.0** (installed 2.17.0 / built 4.12.0 lack the
   provider path — why plans here are hand-rendered).
6. **Dedicated service account** (round-5 §7) — recommended long-term identity;
   not built (credential op).
7. **Then** the wait phrase `implement provider tool`.

**Recommended Phase-B order:** guard impl+tests → rewrite playbooks to `kind:
provider` (guard blocks + 10-project graph) → real `noetl provider plan` for review
→ **youtube-prod first** (20-media + project + billing + APIs, guarded) → rest of
graph → adopt the two existing projects → IAM → (deliberate, gated) place/retire
`shastara` + `My First Project`.

---

## Issues observed

- **`shastara` is orphan AND quota project** — a genuine footgun; excluded from
  bootstrap mutations, quota-repoint-before-retire flagged.
- **adopt tracks but does not conform** — placement into folders is a separate
  gated move; don't expect adopt to reshape the hierarchy.
- Carried: 9 projects + API sets undeclared; shell spec-emitters; `by-display-name`
  + `projects.iam.ensure_binding` gaps; no capable binary (plans hand-rendered).

## Manual escalation needed

- **ADC quota repoint** before ever retiring `shastara` — yours to run.
- **OAuth consent screen + client** for youtube-prod — manual Console.
- **YouTube video upload** — separate playbook/tool, out of `kind: provider`.
- **Delete decisions** (either existing project, or a mis-typed target ID) —
  confirm-gated destroy, human-triggered; I planned none.
- **Dedicated SA** — recommended hardening; credential op, not Phase A.
- Wait phrase `implement provider tool` not given; no Phase B, no builds, no GCP
  writes.

---
**Confirmation (round 6 / Phase A COMPLETE):** verified read-only both existing
projects (`shastara` = orphan/no-parent/ACTIVE and quota project;
`project-83c78291-…` = under org root, no folder, ACTIVE); classified both as
**Untracked** (not orphans) and showed the confirm-gated `adopt` path bringing them
Untracked → Owned **without recreate**, with placement/deletion as separate
deliberate gated steps; flagged `shastara` as the load-bearing ADC quota project
(don't touch mid-run; repoint quota before retiring); reaffirmed the wrong-org
guard (live 403 + offline refusal); delivered reconciled design, full guarded
dependency-ordered dry-run plan (now with an adopt phase), YouTube in/out verdict,
and the irreversibility list with **project-ID-never-reusable** made explicit.
Billing ID + owner email masked; ADC token never printed. **No GCP state created or
modified; no builds; no active-config change.** Holding for `implement provider
tool`.
