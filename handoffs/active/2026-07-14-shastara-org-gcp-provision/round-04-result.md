---
thread: 2026-07-14-shastara-org-gcp-provision
round: 4
from: claude
to: user
created: 2026-07-14T02:25:00Z
in_reply_to: round-04-prompt.md
status: complete
---

# Round 4 — Phase A final: multi-org safety guard designed + refusal proven

Bootstrap is complete: the runner identity holds the org + billing roles. This
round delivers the **multi-org safety guard** (the load-bearing new requirement),
proves the wrong-org refusal, and finalizes the reconciled design, the full
dry-run plan, the YouTube verdict, and the irreversibility list. **Still Phase A —
no remote writes, no GCP mutations, no builds. Only a local no-network guard-logic
demonstration and these two round-04 files.**

**Public-repo hygiene (unchanged):** billing ID + emails masked
(`<BILLING_ACCOUNT_ID>`, "runner identity", "target admin B", "root account"); org
IDs are public. Real billing ID + emails are runtime `--set` only — never
committed.

---

## 0. Bootstrap reality + ADC reminder

- **Runner identity** (`@cybx.io`) has org-level `organizationAdmin`, `folderAdmin`,
  `projectCreator`, `iam.securityAdmin`, `serviceUsageAdmin` on `561323743912` +
  `billing.admin` on `<BILLING_ACCOUNT_ID>`. The §1-round-3 chicken-and-egg is
  resolved.
- **Billing** `<BILLING_ACCOUNT_ID>`: `open: true`,
  `parent: organizations/561323743912` — verified by you via describe.
- **ADC reminder (important):** the provider tool authenticates via **Application
  Default Credentials**, *not* the `gcloud` CLI session. Before any apply-mode run,
  run **`gcloud auth application-default login`** (as the runner identity) so ADC
  is fresh, or point `GOOGLE_APPLICATION_CREDENTIALS` at the runner's key. A stale
  ADC — or one whose **quota project** points at a different estate — is exactly
  the ambient-inheritance risk the guard below defends against.

---

## 1. Multi-org safety guard — design

The runner can see **three real orgs**. A wrong-org folder/IAM write is not a clean
undo. The guard makes a wrong-org run **structurally impossible**, in three layers,
mirroring the destroy/adopt confirm-gate discipline (refuse-by-construction, prove
with tests).

### Layer A — explicit pin (no defaulting, ever)
`ORG_ID` and the billing account are **pinned constants**, never a defaultable
`workload` value that ambient config could override:

- The org target is written as the literal `organizations/561323743912` in every
  org-scoped spec; `shastaratech-org` is the expected display name.
- **Remove the "helpful" default.** Today `org_id: "561323743912"` sits in each
  playbook's `workload` as a *default* — which means `--set org_id=<anything>`
  silently overrides it. Change the contract so ORG_ID is a **required, validated,
  pinned** value: either hardcode the literal in the guarded steps, or keep the
  workload input **but** run it through Layer B before any write so an override to
  a wrong org is rejected rather than honored.

### Layer B — offline STRUCTURAL assertion (works in dry-run, no network)
A **tool-level guard** on every provider step (Phase-B addition, mirroring the
confirm/plan-digest fields already in the tool):

```yaml
tool:
  kind: provider
  provider: google
  action: google.cloudresourcemanager.folders.ensure
  dry_run: "{{ workload.action != 'apply' }}"
  guard:
    require_org: "organizations/561323743912"
    require_org_display_name: "shastaratech-org"   # live check, Layer C
    require_billing_account: "<BILLING_ACCOUNT_ID>" # for billing.link steps
  input: { parent: "organizations/561323743912", display_name: "20-media" }
```

The tool, **before building any request** (so it fires in dry-run, no token, no
network):
- extracts the org from the spec's `parent`/`resource` and refuses with
  `ToolError::Guard` if it != `require_org`;
- for `billing.link`, refuses if the billing account id != `require_billing_account`.

This is the structurally-impossible part for **org-scoped writes** (folders.*,
organizations.iam.*) and **billing id** — the org/id is literally in the request,
so the string check is decisive with zero network.

**Honest nuance — project steps.** A project's `parent` is `folders/<id>` (or
`folders/by-display-name/<name>`) — the **org is not in the string**, so the
offline check can't prove a project lands in the right org by itself. Two things
close it: (a) the parent folder was itself created under the guarded
`organizations/561323743912` earlier in the same run (transitive), and (b) the
Layer-C live check at apply. Don't overclaim: for projects the offline guard is
transitive + live, not a pure string match. Folders and org-IAM are the pure
structural cases.

### Layer C — live BELT-AND-BRACES assertion (apply-mode, needs auth)
At apply time (read-only GETs, so still needs the runner's `auth:`):
- `GET v3/organizations/561323743912` → assert `displayName == "shastaratech-org"`
  (catches a re-pointed/typo'd numeric ID that happens to exist elsewhere);
- `GET v1/billingAccounts/<BILLING_ACCOUNT_ID>` → assert
  `parent == organizations/561323743912` (your verified fact) before any
  `billing.link`;
- for each project's parent folder → `GET v3/folders/<id>` and walk to the org →
  assert ancestry == `561323743912`.

Layer C requires the org GET (`organizations.get`) which the round-1 tool does
**not** yet expose (it has `organizations.iam.get_policy` but no plain
`organizations.get`) — a small Phase-B addition.

### Defense-in-depth — playbook pre-flight step
Independent of the tool guard, add a **first workflow step** that asserts the
pinned constants and hard-fails offline before any provider step runs (a pure
`rhai`/assert step, no network). Belt-and-braces so a step that forgets `guard:`
still can't run against the wrong org.

---

## 2. PROOF — the wrong-org guard refuses (demonstrated)

I cannot run the shipped tool here (no capable binary; Phase A forbids builds), so
I ran a **faithful, no-network demonstration of the exact decision logic** Layer B
performs — the same string comparison the tool will make in dry-run. Output:

```
CASE 1: correct — folders.ensure under shastaratech-org
  [ORG GUARD] OK — organizations/561323743912 matches pinned org 561323743912 (shastaratech-org)
   -> would proceed to build folders.ensure plan
CASE 2: WRONG org — --set org_id=103794563683 (adiona.org)
  [ORG GUARD] REFUSED — target 103794563683 != pinned 561323743912. No request built, no network call.
   -> plan HALTS; zero folders/IAM planned in adiona.org
CASE 3: WRONG org — cyberionix.com 712221118891
  [ORG GUARD] REFUSED — target 712221118891 != pinned 561323743912. No request built, no network call.
   -> plan HALTS; zero resources planned in cyberionix.com
CASE 4: correct billing account — [BILLING GUARD] OK
CASE 5: WRONG billing account — [BILLING GUARD] REFUSED — ... != pinned. No link built.
```

This proves the *decision*: a wrong ORG_ID (both real sibling orgs the runner can
actually reach) and a wrong billing account are refused **before any request is
built**, with no network. **Phase B lands this as tool code + the unit tests that
assert it**, exactly as destroy/adopt were proven (`destroy_stale_confirm_digest_is_refused`,
`adopt_blind_apply_without_confirm_is_refused`, …). The new tests to write:

- `guard_wrong_org_id_is_refused_offline` (dry-run, no network) — org 103794563683
  and 712221118891 both REFUSED.
- `guard_correct_org_id_passes_offline`.
- `guard_wrong_billing_account_is_refused_offline`.
- `guard_org_display_name_mismatch_refused_apply` (live, mocked GET).
- `guard_billing_parent_not_org_refused_apply` (live, mocked GET).

(These are Phase-B deliverables — flagged, not built. The demonstration above is
the logic, not the shipped binary.)

---

## 3. Reconciled design (against real ORG_ID / billing / folder structure)

- **ORG_ID `561323743912` = shastaratech-org** — real, verified, pinned (Layer A).
- **Billing `<BILLING_ACCOUNT_ID>`** — real, `open`, parented to the org; pinned +
  Layer-C asserted before link.
- **Folders (5):** `org_folders.yaml` matches the target exactly.
- **Projects (10) → folder mapping** (the desired graph; still **not encoded as
  playbook data** — round-3 gap, unchanged):
  - `00-shared`: shastaratech-billing-admin, shastaratech-dns-prod, shastaratech-observability-prod
  - `10-platform`: shastaratech-noetl-dev, shastaratech-noetl-prod, shastaratech-ai-lab
  - `20-media`: **shastaratech-youtube-prod** (priority)
  - `30-websites`: shastaratech-web-dev, shastaratech-web-prod
  - `90-sandbox`: shastaratech-sandbox
- **Per-project API sets:** only youtube-prod specified; other 9 **undeclared**
  (round-3 gap).
- **Wiring:** still `kind: shell` spec-emitters — Phase B rewrites to `kind:
  provider` steps (with `guard:` blocks).
- **`stack: shastaratech-org-foundation`** ownership label (round-1).

---

## 4. Dry-run PLAN — full desired state, dependency order

Rendered as the `would_call` shape (method + URL + body-shape; no token, no
network). **Every write-capable step carries the `guard:` block from §1.**

**Phase 0 — guard pre-flight (offline + live):** assert pinned org == 561323743912
(display `shastaratech-org`) and billing == `<BILLING_ACCOUNT_ID>`
(parent == org). HARD FAIL halts the run. *(Proven in §2.)*

**Phase 1 — folders** (`reconcile: enforce`, GET-first, guard on):
`POST cloudresourcemanager.googleapis.com/v3/folders`
body `{parent:"organizations/561323743912", displayName:"<00-shared|10-platform|20-media|30-websites|90-sandbox>"}` ×5.
Each returns a numeric folder id → feeds Phase 2.

**Phase 2 — projects** (guard transitive+live, GET-first):
`POST …/v3/projects` body `{projectId:"<id>", displayName:…, parent:"folders/<folder id>"}`
for all 10 IDs (youtube-prod → `folders/<20-media id>`, etc. per §3 mapping).

**Phase 3 — billing link** (guard: billing id + parent==org, idempotent PUT):
`PUT cloudbilling.googleapis.com/v1/projects/<project_id>/billingInfo`
body `{billingAccountName:"billingAccounts/<BILLING_ACCOUNT_ID>"}` ×10.

**Phase 4 — API enable** (Service Usage, idempotent POST):
youtube-prod: `POST serviceusage.googleapis.com/v1/projects/shastaratech-youtube-prod/services/<svc>:enable`
for `youtube.googleapis.com`, `iam.googleapis.com`, `serviceusage.googleapis.com`,
`cloudresourcemanager.googleapis.com`. **Other 9 projects: API sets undeclared —
can't render; needs your input.**

**Phase 5 — IAM** (read-modify-write, etag):
- Org IAM: target admins × role bundle → `POST …/v3/organizations/561323743912:setIamPolicy`.
- Billing IAM: admins × `roles/billing.admin` → `POST …/v1/billingAccounts/<BILLING_ACCOUNT_ID>:setIamPolicy`.
- Project-level IAM: **no tool action exists** (`projects.iam.ensure_binding`
  missing) — Phase-B addition if needed.

Plan-mode result per step: `{provider, action, dry_run:true, changed:false,
backend:"rest", would_call:{method,url,body_shape}, guard:"passed"}` — no network.
**`reconcile: enforce` required** or an apply reports drift and changes nothing.

---

## 5. YouTube scope verdict

- **IN scope for `kind: provider`:** create `shastaratech-youtube-prod`, link
  billing, `services.enable youtube.googleapis.com` — CRM v3 + Billing v1 +
  Service Usage v1. Stands the project up and turns the API on.
- **OUT of scope — uploading videos.** YouTube Data API v3 `youtube.videos.insert`
  — content publishing, not infra. **Data-plane** API (not CRM/Billing/
  ServiceUsage); **3-legged OAuth** where a human channel owner consents and you
  post *as* that YouTube account (a service-account ADC cannot own/post to a
  channel); **resumable media upload** with per-video quota cost. The tool has no
  verb for it and shouldn't grow one.
- **What carries the upload:** a **separate NoETL playbook** — an `http`+OAuth2
  step or a dedicated `youtube` tool kind — its own thread. **Manual prerequisite:**
  the **OAuth consent screen + OAuth client** for the project (Console/IAP brand,
  not in the tool's three APIs). Don't fold either into provisioning.

---

## 6. Irreversibility / high-blast-radius risks

1. **10 globally-unique, never-reusable project IDs.** A typo mints a permanent
   wrong ID; delete → ~30-day soft-delete → **permanently retired, never reusable
   by anyone**. Triple-check all 10, especially `-prod`.
2. **Org/billing `setIamPolicy` lockout.** Whole-policy read-modify-write; a wrong
   role or lost-etag race can revoke org-admin → **Google support ticket** to
   recover. Keep the **root account** as untouched break-glass; never manage it via
   automation.
3. **Wrong-ORG writes** (the reason for §1) — folders/IAM landed in adiona.org or
   cyberionix.com are org-scope mistakes with no clean undo. The guard makes this
   structurally impossible; that's why it's mandatory, not optional.
4. **Folder deletion / re-parenting** — folder deletes only when empty; moving a
   folder/project silently changes inherited IAM.
5. **Billing detach** can shut down resources and, after a grace period, **delete
   data** (Cloud SQL, disks). Linking starts metered cost on API enable.
6. **Org policy** — not in scope; if ever added, applies org-wide and can lock out
   the whole subtree. Sharpest edge; keep it a conscious decision.
7. **Existing `shastara` project** (round-3 §6) — keep-as-sandbox (move to
   `90-sandbox`, a mutation) **or** confirm-gated delete. I planned neither;
   recommend move-to-sandbox. Deletion is a deliberate gated destroy you trigger.

Safe/reversible: list/describe, `get_policy`, `services.enable`. Dangerous: the 10
ID mints, any `setIamPolicy`, billing link/detach, folder deletion, wrong-org
writes, org policy.

---

## 7. What's needed before Phase B

1. **Refresh ADC** — `gcloud auth application-default login` as the runner
   identity (the tool uses ADC, not the CLI session). Confirm the ADC **quota
   project** isn't pointing at adiona/cyberionix.
2. **Declare the 9 non-youtube projects as data** + **their per-project API sets**
   (undeclared — §3).
3. **Confirm all 10 project IDs** (irreversible — §6.1).
4. **Decide the existing `shastara` project** — move-to-sandbox (recommended) vs.
   confirm-gated delete.
5. **Accept the Phase-B tool additions** the full run needs:
   - the `guard:` block (`require_org` / `require_org_display_name` /
     `require_billing_account`) + `organizations.get` for Layer C + the guard unit
     tests (§2);
   - `by-display-name` parent resolution (verify in 3.25.0, else two-phase folders→projects);
   - `projects.iam.ensure_binding` (only if you need per-project role grants).
6. **Build/install noetl-cli ≥4.17.0** (installed 2.17.0 / built 4.12.0 can't run
   the provider path).
7. **Then** the wait phrase `implement provider tool`.

**Recommended Phase-B sequence when you're ready:** (1) implement + unit-test the
guard; (2) rewrite the playbooks to `kind: provider` with `guard:` blocks + the
declared 10-project graph; (3) `noetl provider plan` the whole graph for your
review (real dry-run, no writes); (4) **youtube-prod first** — the priority slice —
apply folder `20-media` + project + billing + APIs under the guard; (5) the rest of
the graph; (6) IAM. Each apply gated, guard-asserted, reviewed.

---

## Issues observed

- **`org_id` is a defaultable `workload` value today** → `--set` can override it to
  a wrong org. The guard (Layer A pin + Layer B assert) must neutralize this before
  any write.
- **Project offline guard is transitive+live, not pure-structural** (org not in a
  project's parent string) — stated honestly, not overclaimed.
- **`organizations.get` not exposed by the tool** — Layer-C display-name check
  needs it (small Phase-B add).
- **9 projects + their API sets still undeclared**; playbooks still shell
  spec-emitters; `by-display-name` + `projects.iam.ensure_binding` gaps — all
  carried from earlier rounds.
- **No capable binary here** — guard proof is the decision-logic demonstration +
  the Phase-B test spec, not a live tool run.

## Manual escalation needed

- **ADC refresh** (`gcloud auth application-default login`) + quota-project check —
  yours to run.
- **OAuth consent screen + client** for youtube-prod — manual Console step.
- **YouTube video upload** — separate playbook/tool, out of `kind: provider`.
- **Existing `shastara` project** decision — gated, yours to trigger.
- Wait phrase `implement provider tool` not given; no Phase B, no builds, no GCP
  writes. This round: one local no-network guard demo + two round-04 files.

---
**Confirmation (round 4 / Phase A complete):** designed the three-layer multi-org
guard (pin + offline structural assert + live belt-and-braces + playbook pre-flight)
mirroring the destroy/adopt gate discipline; **proved the refusal** — wrong org
(adiona 103794563683, cyberionix 712221118891) and wrong billing account both
REFUSED with no network, correct target accepted — via a faithful no-network
decision-logic demonstration, with the Phase-B unit-test spec that will assert it
in the shipped tool; reconciled the design against the real org/billing/folders;
rendered the full guarded dependency-ordered dry-run plan; gave the YouTube in/out
scope verdict; listed the irreversible risks; stated exactly what's needed before
Phase B. Billing ID + emails masked. **No GCP state created or modified; no builds;
no active-config change.**
