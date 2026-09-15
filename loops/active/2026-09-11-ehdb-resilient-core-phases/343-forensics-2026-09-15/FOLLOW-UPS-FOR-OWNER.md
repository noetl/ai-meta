# Follow-ups for the owner — 2026-09-15

Three decisions left from the prod-restore / adiona-validation session. None was
actioned; all are owner calls. Context: `SESSION-SUMMARY.md`.

---

## (a) Reconcile the planner: merge `fix/341-children-paxes`, then register once

**Why:** prod runs planner v113 = commit `caf76bf` on
`origin/fix/341-children-paxes`, which is **not merged to main**. It carries two
hotel fixes main lacks:

```
caf76bf  fix(hotels): send a paxes element per child so family searches work
8f10fd0  fix(hotels): derive stay dates at execution time; guard and classify
         provider failures
```

main carries one thing prod lacks: the offer-cap 10→50 change from
adiona/frontend#21 (`06dcaed`).

**Registering main as-is would drop the two hotel fixes from production.**

**Do:** review and merge `fix/341-children-paxes` → `main`, then register main
once. That ships the cap without losing the hotel fixes.

**Until then:** `main` is not a safe source to register for
`muno/playbooks/itinerary-planner`. Prod and git have genuinely diverged.

Effort: a review + merge. No prod risk once merged.

---

## (b) Platform: hydrate `noetl://` refs on the consume path  ← the blocker

**Why:** a `kind: playbook` child result over the runtime byte budget is stored
out of line and the parent step receives
`{"_ref": "noetl://execution/<eid>/result/<step>/<id>"}`. Hydration is
**read-side only** (`hydrate_result_references` on API read), so a step consuming
the value mid-workflow sees nothing — **silently**, `status: success`, empty list,
no error.

Measured: `hotel-cards` returned 0 hotels on four consecutive prod runs while the
child had fetched 5 hotels / 509 images / 67 rates (214,805 bytes).

**This blocks adiona/frontend#22 end-to-end.** The provider work is validated;
the cards cannot be delivered until this is resolved.

**Options seen from outside the runtime:**
1. Hydrate references when rendering a step's input (the consume path), not only
   on API read — the sanctioned shape, and it fixes every `kind: playbook`
   caller at once.
2. Expose a deref endpoint (`GET /api/result?ref=noetl://…`) so a consumer can
   resolve explicitly. Narrower; each playbook must opt in.
3. Raise the externalisation floor. A workaround, not a fix — it moves the cliff
   rather than removing it.

**Do NOT** reimplement the result-tier client inside playbooks. The payload is in
GCS at
`…/execution=<eid>/results/<step>/0/0/1.json`, but `region`/`cell`/`shard` are
not derivable from the reference `uri`, so it would require listing and would
duplicate platform logic in every playbook.

⚠ Whoever picks this up: the API returns the reference plus `extracted`
metadata, and `extracted` is flagged **`_truncated`**. It is a SAMPLE. An early
mitigation in this session used it and reported 1 hotel as the whole answer —
silently wrong, and it would have passed a smoke test.

**Interim shipped:** noetl/travel#122 makes both playbooks refuse truncated data
and report `deref_error` naming the cause and byte size. Fail-loud, not silent.
It does not make hotels work.

Effort: a server change plus a release. Outside the travel work.

---

## (c) Optional: a playbook-registration ledger

**Why:** `ci/manifests/noetl/RELEASE-LEDGER.md` is an append-only ledger of
**component image digests** for DR, and its own header says the recording step is
not wired. Playbook catalog registrations are not image releases, so this
session's registrations were deliberately **not** appended there.

There is currently no durable record of *which playbook content is registered to
prod, when, and from which git sha* — which is exactly the gap that produced two
wrong readings this session ("prod is 17 commits behind main"; "the registered
duffel is current"). Prod had been running a provider pointing at a **retired**
GCP project for months because a merged fix was never registered.

**Do (if wanted):** a `ledger/playbooks.tsv` in the same append-only shape:

```
# path	version	catalog_id	git_sha	registered_at	sha256
muno/playbooks/flights-details	3	716…	06dcaed	2026-09-15T07:5xZ	…
```

Cheap, and it makes "is prod running what git says?" answerable without
diffing blobs against every commit.

Effort: small. Pure record-keeping; no prod behaviour change.
