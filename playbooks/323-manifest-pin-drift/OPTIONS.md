# #323 — the stale-manifest DR hazard: options, tradeoffs, a recommendation

**Status: a decision document. Nothing here is built or applied.**

## The hazard

Every image pin in `repos/ops/ci/manifests/noetl/` is behind what prod runs.
Prod is deployed **by digest** (`crane` GHCR→AR, then `kubectl set image`), and
nothing writes that digest back to the manifests. So the manifests are a
[representation](../../agents/rules/representation-drift.md) with **no forcing
function**: ask the rule's two questions and both answers are bad.

1. *What forces this to agree with reality?* Someone remembering.
2. *If it disagreed, how would anyone find out?* Only by already suspecting it.

A DR apply — the one moment the manifests are load-bearing — rolls prod back
past every fix deployed since the last hand-edit. Today that includes at least
the #320 mirror-loss fix and the #326 write-path fix.

The drift is **structural, not accidental**: the deploy path and the declaration
path are disjoint, so any amount of care upstream leaves them disagreeing.

## Options

### A — Automated pin-sync (a job writes the manifests back)

A scheduled job reads the live digests and commits them to `ci/manifests`.

* **For:** the manifests become true continuously; no human ritual.
* **Against:** the manifests stop being a *declaration* and become a *report*.
  Anyone reading them as intent is misled in a new way, and a bad prod state
  gets committed as the desired state — the drift is fixed by making the copy
  authoritative, which is the wrong direction for IaC.
* **Also:** a bot committing to `ops` needs write credentials, which is new
  attack surface for a repo that is already public.

### B — Remove manifests as the source of image pins

Strip `image:` from the manifests entirely; a deploy names the digest
explicitly (as it already does). The manifests declare *shape*, not *version*.

* **For:** removes the false claim rather than trying to keep it true. A
  representation that does not exist cannot drift — the strongest fix available
  and the only one that is structural.
* **Against:** `kubectl apply` of a manifest with no image is not a complete
  deploy, so DR needs a companion source for "which digest". That source has to
  live somewhere and be kept current — which is the same problem, relocated,
  unless it is derived (see D).
* **Note:** this is closest to how prod already behaves. The manifests are
  *already* not the pin source; option B makes the file honest about it.

### C — A CI gate that blocks apply when pins lag prod

CI compares manifest pins against live digests and fails when they differ.

* **For:** cheap, no new write path, and it converts a silent divergence into a
  loud one — exactly the property the drift rule asks for.
* **Against:** it only fires when CI runs. A DR apply during an incident is
  precisely when nobody is running CI, so the gate is absent at the one moment
  it matters. It also needs cluster read credentials in CI.
* **This is a detector, not a fix.** Worth having; not sufficient alone.

### D — Derive the DR input from the cluster at DR time

DR reads the running digests from the cluster (or from the last-known-good
digest recorded per release) rather than from a checked-in file.

* **For:** *prefer derivation over denormalization* — the drift rule's own
  guidance. There is no second copy to go stale.
* **Against:** in the DR scenario where the cluster is gone, there is nothing to
  read. Needs a durable per-release digest record (a release artifact, not a
  hand-edited manifest) as the fallback — which is small, append-only, and
  written by the release job that already knows the digest.

## Recommendation

**B + D, with C as the detector.**

* **B** removes the false claim instead of maintaining it. The manifests keep
  declaring shape — replicas, probes, env, resources — which is what they are
  actually good for and what genuinely belongs in review.
* **D** gives DR a digest source that is *written by the thing that knows*: the
  release job already resolves the AR digest (this session read it four times
  today). Appending it to a per-repo release ledger costs one step and creates
  a record that is correct by construction rather than by ritual.
* **C** stays as the cheap loud check, with its limitation stated: it does not
  protect a DR apply, it protects the everyday one.

**Not A.** It fixes the symptom by promoting the copy to authoritative, and it
buys a bot write-credential on a public repo to do it.

## What this does not decide

Whether the ops manifests should describe prod at all, versus prod being a
Helm release with values. That is a larger question and this document
deliberately does not answer it.

## The "outside actor" — closed, read-only

A standing concern held that an unexplained principal was patching prod
Deployments. A 30-day census of `deployments.update|patch` says otherwise:

| principal | patches | what it is |
| :-- | --: | :-- |
| `shastaratech@gmail.com` | 198 | **this session's own deploy identity** — the account every `gcloud` / `crane` / `kubectl` call here uses |
| `kadyapam@gmail.com` | 2 | the owner's account |
| `system:serviceaccount:noetl:noetl-state-builder-watchdog` | 16 | in-cluster, scales the system pool |
| `system:addon-manager` | ~139 | GKE's own addons (kube-dns, gmp-operator, …) |

**No third party.** The volume attributed to `shastaratech@` is consistent with
agent-driven deploys across these sessions — five of them today, at times
matching this session's own rollouts. The concern is closed as self-attribution;
the lesson is the one already recorded, that *other sessions act on prod
concurrently* — including one's own earlier sessions, which read as "someone
else" when the identity is not checked.
