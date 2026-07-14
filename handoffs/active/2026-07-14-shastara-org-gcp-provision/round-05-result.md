---
thread: 2026-07-14-shastara-org-gcp-provision
round: 5
from: claude
to: user
created: 2026-07-14T03:25:00Z
in_reply_to: round-05-prompt.md
status: complete
---

# Round 5 — Phase A final: acting identity verified org-scoped; blast radius eliminated

The acting-identity change is **verified real, not assumed**: ADC resolves to the
shastaratech owner account, which can reach **exactly one org** (shastaratech-org)
and is **structurally denied** on the other two. That converts the multi-org risk
from *guarded* to *eliminated at the identity boundary* — the guard stays as
defense-in-depth. This closes Phase A. **No remote writes: only read-only GET /
search / getIamPolicy introspection with the ADC token (never printed) + a local
no-network guard demo + these two round-05 files.**

**Public-repo hygiene:** billing ID + the owner email masked (`<BILLING_ACCOUNT_ID>`,
"the shastaratech owner account (ADC identity, a `@gmail.com` account)"). Org IDs
are public. The ADC access token was used transiently and **never echoed or
committed**.

---

## 0. Pre-flight verification — all assertions PASS

| Check | Method (read-only) | Result |
| --- | --- | --- |
| **ADC identity** | `tokeninfo` on `print-access-token` | ✅ the **shastaratech owner account** (`email_verified: true`), scope `cloud-platform` + `userinfo.email`. **Not** the `@cybx.io` identity. CLI session matches. |
| **Org visibility** | `GET cloudresourcemanager v3/organizations:search` (ADC token) | ✅ **exactly one org**: `shastaratech-org / organizations/561323743912 / state=ACTIVE`. **count = 1.** adiona.org and cyberionix.com are **not visible** to this credential. |
| **Roles on org** | `POST v3/organizations/561323743912:getIamPolicy` (ADC token) | ✅ owner holds `resourcemanager.organizationAdmin`, `resourcemanager.projectCreator`, `resourcemanager.projectMover`, `serviceusage.serviceUsageAdmin`, `billing.admin` (+ `billing.creator`, `iam.workforcePoolAdmin`). **organizationAdmin subsumes folderAdmin** (folder create/move/delete). Sufficient for the whole graph. |
| **Billing account** | `GET cloudbilling v1/billingAccounts/<BILLING_ACCOUNT_ID>` (ADC token) | ✅ `open: true`, `parent: organizations/561323743912`. Linkable, parented to the target org. |

**Bottom line:** the identity gate is open, correctly scoped, and correctly
privileged. Running as this owner account means a wrong-org write isn't merely
refused by policy — the credential **can't see the other orgs to begin with**.

---

## 1. Proof of the wrong-org guard — BOTH layers demonstrated

You asked for the refusal shown, not asserted. Two independent proofs:

### (a) LIVE — the acting identity cannot even reach the other orgs
Read-only `getIamPolicy` with the ADC token against the two sibling orgs:

```
getIamPolicy adiona.org      (103794563683)  ->  HTTP 403
getIamPolicy cyberionix.com  (712221118891)  ->  HTTP 403
```

The identity is **denied** on both. A misdirected write to adiona/cyberionix is
**impossible for this credential** — the strongest possible guard, enforced by
Google, not by our code.

### (b) OFFLINE — the tool guard refuses a wrong ORG_ID before any request
The designed Layer-B structural guard (round 4), demonstrated with the faithful
no-network decision logic:

```
CASE 2: WRONG org --set org_id=103794563683 (adiona.org)
  [ORG GUARD] REFUSED — target 103794563683 != pinned 561323743912. No request built, no network call.
CASE 3: WRONG org 712221118891 (cyberionix.com)
  [ORG GUARD] REFUSED — target 712221118891 != pinned 561323743912. No request built, no network call.
  [BILLING GUARD] REFUSED — wrong billing account != pinned. No link built.
```

**Why keep the offline guard even though the identity can't reach other orgs?**
Defense-in-depth, and it becomes load-bearing again the moment the acting identity
changes to a multi-org one — exactly the future dedicated-SA case (§8) if that SA
were ever over-granted. The two layers are independent: identity-scoping
(eliminates) + tool guard (refuses cleanly, offline) + Layer-C live display-name/
parent assert (catches a re-pointed numeric ID). Phase B lands the guard as tool
code + the unit tests named in round 4 (`guard_wrong_org_id_is_refused_offline`, …).

---

## 2. Reconciled design (against verified ORG_ID / billing / folders)

- **ORG_ID `561323743912` = shastaratech-org** — real, ACTIVE, the *only* org the
  acting identity sees. Pinned (never defaulted).
- **Billing `<BILLING_ACCOUNT_ID>`** — `open`, parented to the org; pinned +
  Layer-C asserted before link.
- **Acting identity** — the shastaratech owner account (ADC), correctly
  org-scoped and privileged. *(Long-term: replace with a dedicated SA — §8.)*
- **Folders (5):** `org_folders.yaml` matches target exactly.
- **Projects (10) → folders** — the desired graph, still **not encoded as playbook
  data** (carried gap):
  - `00-shared`: shastaratech-billing-admin, shastaratech-dns-prod, shastaratech-observability-prod
  - `10-platform`: shastaratech-noetl-dev, shastaratech-noetl-prod, shastaratech-ai-lab
  - `20-media`: **shastaratech-youtube-prod** (priority)
  - `30-websites`: shastaratech-web-dev, shastaratech-web-prod
  - `90-sandbox`: shastaratech-sandbox
- **Per-project API sets:** only youtube-prod specified; other 9 **undeclared**.
- **Wiring:** still `kind: shell` spec-emitters → Phase B rewrites to `kind:
  provider` steps with `guard:` blocks.
- **`stack: shastaratech-org-foundation`** ownership label.

---

## 3. Dry-run PLAN — full desired state, dependency order (guarded)

`would_call` shape (method + URL + body-shape; no token, no network). Every
write-capable step carries the `guard:` block (`require_org:
"organizations/561323743912"`, `require_org_display_name: "shastaratech-org"`,
`require_billing_account: "<BILLING_ACCOUNT_ID>"`).

- **Phase 0 — guard pre-flight** (offline pin assert + live GETs now
  demonstrable): org search → 1 org; org display == shastaratech-org; billing
  open + parent == org. HARD FAIL halts. *(All four verified live in §0.)*
- **Phase 1 — folders** `POST crm/v3/folders` `{parent:"organizations/561323743912",
  displayName:"<00-shared|10-platform|20-media|30-websites|90-sandbox>"}` ×5;
  GET-first idempotent; each returns a numeric id → Phase 2.
- **Phase 2 — projects** `POST crm/v3/projects` `{projectId:"<id>", displayName:…,
  parent:"folders/<folder id>"}` ×10 (youtube-prod → `folders/<20-media id>`);
  GET-first.
- **Phase 3 — billing link** `PUT cloudbilling/v1/projects/<project_id>/billingInfo`
  `{billingAccountName:"billingAccounts/<BILLING_ACCOUNT_ID>"}` ×10.
- **Phase 4 — API enable** `POST serviceusage/v1/projects/<id>/services/<svc>:enable`
  — youtube-prod: `youtube`, `iam`, `serviceusage`, `cloudresourcemanager`. **Other
  9: API sets undeclared — can't render; needs your input.**
- **Phase 5 — IAM** — org IAM (target admins × role bundle → org `:setIamPolicy`);
  billing IAM (admins × `billing.admin` → billing `:setIamPolicy`); **project-level
  IAM has no tool action** (`projects.iam.ensure_binding` missing) — Phase-B add if
  needed.

`reconcile: enforce` required, or an apply reports drift and changes nothing.
`by-display-name` parent resolution unverified in 3.25.0 → if absent, two-phase
(folders → capture ids → projects).

---

## 4. YouTube scope verdict

- **IN scope for `kind: provider`:** create `shastaratech-youtube-prod`, link
  billing, `services.enable youtube.googleapis.com`. CRM v3 + Billing v1 + Service
  Usage v1 — the tool's wheelhouse. Stands the project up, turns the API on.
- **OUT of scope — uploading videos.** YouTube Data API v3 `youtube.videos.insert`
  — content publishing, not infra. Data-plane (not CRM/Billing/ServiceUsage);
  **3-legged OAuth** where a human channel owner consents and you post *as* that
  YouTube account (a service-account/ADC identity cannot own/post to a channel);
  resumable media upload with per-video quota. No tool verb; shouldn't grow one.
- **Carried by:** a separate NoETL playbook (`http`+OAuth2 or a dedicated
  `youtube` tool). **Manual prerequisite:** OAuth consent screen + client
  (Console/IAP brand — not in the three APIs). Note the channel-owner OAuth is a
  *different* identity from the provisioning ADC — the SA that builds the project
  is not the account that owns the YouTube channel.

---

## 5. Irreversibility / high-blast-radius risks

1. **10 globally-unique, never-reusable project IDs** — a typo mints a permanent
   wrong ID; delete → ~30-day soft-delete → **permanently retired**. Triple-check,
   especially `-prod`.
2. **Org/billing `setIamPolicy` lockout** — whole-policy read-modify-write; a wrong
   role/lost-etag can revoke org-admin → Google support ticket. **Keep the owner
   account as untouched break-glass**; don't let automation manage it.
3. **Wrong-ORG writes** — now eliminated at the identity (403 on other orgs) +
   guarded offline. Retained as risk-of-record because it re-arms if the acting
   identity changes.
4. **Folder deletion / re-parenting** — deletes only when empty; moves silently
   change inherited IAM.
5. **Billing detach** — can shut down resources and delete data after grace; link
   starts metered cost on API enable.
6. **Org policy** — out of scope; org-wide blast radius if ever added.
7. **Existing `shastara` project** — keep-as-sandbox (move to `90-sandbox`) vs.
   confirm-gated delete; I planned neither, recommend move.

Safe/reversible: list/describe, get_policy, `services.enable`. Dangerous: the 10 ID
mints, any `setIamPolicy`, billing link/detach, folder deletion, org policy.

---

## 6. What remains before Phase B

1. **Declare the 9 non-youtube projects as data** + **per-project API sets**
   (undeclared).
2. **Confirm all 10 project IDs** (irreversible).
3. **Decide the existing `shastara` project** (move-to-sandbox recommended vs.
   gated delete).
4. **Phase-B tool additions** the full run needs: `guard:` block (`require_org` /
   `require_org_display_name` / `require_billing_account`) + `organizations.get`
   for Layer C + guard unit tests; `by-display-name` parent resolution (verify in
   3.25.0); `projects.iam.ensure_binding` if per-project grants needed.
5. **Build/install noetl-cli ≥4.17.0** (installed 2.17.0 / built 4.12.0 can't run
   the provider path — why every plan here is hand-rendered, not executed).
6. **Then** the wait phrase `implement provider tool`.

**Recommended Phase-B order:** implement+test the guard → rewrite playbooks to
`kind: provider` with `guard:` + the 10-project graph → real `noetl provider plan`
for review → **youtube-prod first** (20-media + project + billing + APIs, guarded)
→ rest of graph → IAM. Each apply gated, guard-asserted, reviewed.

---

## 7. Identity recommendation for the record — dedicated service account

The owner account (a human `@gmail.com`) is the right **bootstrap** identity and a
fine **org-scoped** one, but the **long-term correct** answer is a **dedicated
service account inside shastaratech-org** with only the roles the playbooks need
(folderAdmin or organizationAdmin-scoped-narrower, projectCreator,
serviceUsageAdmin, billing.user/admin on the billing account). Rationale:

- **Automation shouldn't run as a human** — a personal account's compromise,
  MFA-reset, or offboarding shouldn't take out the provisioning path; and human
  ADC tokens expire/rotate awkwardly for unattended runs.
- **An SA created inside shastaratech-org also can't see the user's other orgs** —
  it inherits the same single-org blast-radius elimination, by construction.
- **Least privilege + auditability** — scoped roles + its own audit trail;
  referenceable by keychain alias for the provider tool's `auth:`.

**Recommend, do NOT build now** — SA creation + key/WI setup is itself a
provisioning step, and minting an SA key is a credential operation I won't do in
Phase A. Flag it as the first hardening task after the initial bootstrap lands.

---

## Issues observed

- **9 projects + their API sets still undeclared**; playbooks still shell
  spec-emitters; `by-display-name` + `projects.iam.ensure_binding` gaps — carried.
- **No capable binary here** — plans hand-rendered; guard proof is the LIVE 403 +
  the offline decision-logic demo + the Phase-B test spec, not a shipped-tool run.
- **`org_id` still a defaultable workload value** in the playbooks — the pin
  (Layer A) must neutralize `--set` override even though the identity now can't
  reach other orgs.

## Manual escalation needed

- **OAuth consent screen + client** for youtube-prod — manual Console step.
- **YouTube video upload** — separate playbook/tool, out of `kind: provider`; note
  its OAuth identity ≠ the provisioning ADC.
- **Existing `shastara` project** decision — gated, yours to trigger.
- **Dedicated SA** (§7) — recommended hardening; a credential/provisioning step,
  not done in Phase A.
- Wait phrase `implement provider tool` not given; no Phase B, no builds, no GCP
  writes. This round: read-only ADC introspection + a local guard demo + two
  round-05 files.

---
**Confirmation (round 5 / Phase A COMPLETE):** verified read-only that ADC =
the shastaratech owner account (not the `@cybx.io` identity), that it sees exactly
one org (shastaratech-org / 561323743912, count=1), holds the org + billing roles
needed, and that the billing account is open + parented to the org; proved the
wrong-org guard BOTH live (HTTP 403 on adiona + cyberionix — the identity cannot
reach them) and offline (tool guard refuses wrong ORG_ID with no network);
delivered the reconciled design, the full guarded dependency-ordered dry-run plan,
the YouTube in/out scope verdict, and the irreversibility list; recorded the
dedicated-SA recommendation. Billing ID + owner email masked; ADC token never
printed. **No GCP state created or modified; no builds; no active-config change.**
Holding for `implement provider tool`.
