# Apply safety — never apply a manifest you have only partly compared

A gate, not a guideline. It exists because the alternative was tried and cost a
55-minute production outage on 2026-09-08.

## The rule

**Before any `kubectl apply` against prod, diff the FULL rendered object against
live.** Not the field you changed. Not the field you are worried about. The
whole object.

```bash
kubectl --context "$PROD" -n noetl diff --server-side -f <manifest>
```

Read every hunk. Apply only when you can say what each one does. A hunk you
cannot explain is a hunk you have not verified, and "it's probably fine" is the
sentence that precedes the incident.

`playbooks/drift-audit.sh manifest-vs-live` runs the mechanical half of this —
it flags anything declared in a manifest and absent from the live object, which
is the shape that bites.

## Why a targeted dry-run is not enough

**A dry-run answers only the question you ask it.**

On 2026-09-08 the pre-apply proof for [#323](https://github.com/noetl/ai-meta/issues/323)
was a server-side dry-run across five prod workloads, checking that removing the
image pin preserved the running digest. It did — all five, with a negative
control showing the method could detect a change. That evidence was real.

It was also evidence about **one field**. The same manifest declared a fourth
volume for PVC `noetl-ehdb-tier-0-data`, which has never existed in prod. The
apply added it to a running StatefulSet; the pod could no longer schedule:

```
FailedScheduling: persistentvolumeclaim "noetl-ehdb-tier-0-data" not found
```

That writer hosts both the command bus and the event bus, so every worker pool
went to `EHDB claim connect failed` and dispatch stopped for ~55 minutes.

`kubectl diff` against live would have shown the added volume outright, in the
same second, at no cost. The proof that was run was narrower than the action it
authorised — and **the gap between what you verified and what you changed is
exactly where the incident lives.**

## The second half: an apply is not a no-op just because the spec is equivalent

The same session predicted that a "shape-only" apply would cause zero rollouts.
Three of five workloads rolled.

**Anything under `spec.template` is part of the pod template hash.** Removing
`kubectl.kubernetes.io/restartedAt` and the watchdog annotations — runtime
fields that never belonged in the manifest — changed the hash and rolled the
workload *by construction*. The mechanism was plainly visible; it was asserted
away rather than checked.

So: **before applying, state what will restart, and check it.** If the diff
touches `spec.template` in any way, the workload rolls. Plan for it, or do not
apply during a window where a roll is unacceptable.

## What to verify, concretely

For every workload in the manifest:

| | why |
| :-- | :-- |
| volumes, and the **PVCs they claim actually exist** | the #323 shape exactly |
| volumeMounts per container | an orphan mount is the same failure |
| container names | a container the cluster has never seen |
| `spec.template` metadata | tells you whether it rolls |
| resources, probes, replicas | ordinary shape drift |

The direction that matters is **manifest has it, live does not**. The reverse is
usually deliberate — it is what shape-only manifests do — and flagging it would
make the check noisy enough to ignore, which is its own failure mode.

## When this rule does not fire

- Applying to a scratch or kind cluster. Break those freely; that is what they
  are for.
- Creating a namespace's objects from nothing, where there is no live object to
  diff against. Then the risk is different: the manifest is the only source, so
  review it as such.

## Related

- [`representation-drift.md`](representation-drift.md) — the manifests were a
  drifting representation; this rule governs what to do before acting on one.
- [`deployment-validation.md`](deployment-validation.md) — kind validation
  before prod. Complementary: that checks the image, this checks the spec.
- [`playbooks/323-manifest-pin-drift/OPTIONS.md`](../../playbooks/323-manifest-pin-drift/OPTIONS.md)
  — the design work the incident happened during.

## History

Codified 2026-09-08, the day of the outage, from two errors in one apply:
verifying one field and generalising it to the object, and predicting a
restart-free apply while removing pod-template annotations.
