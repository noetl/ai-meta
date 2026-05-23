---
thread: 2026-05-23-phase4-nats-supercluster
round: 1
from: claude
to: claude
created: 2026-05-23T05:00:00Z
status: open
expects_result_at: round-01-result.md
---

# Phase 4 round 3: NATS supercluster topology

> **Predecessor:** Phase 4 round 2 closed in
> `handoffs/archive/2026-05-23-phase4-keda-scaler/` (PR #594,
> noetl `f574b328`, v2.99.0). This is the **last v2-spec round** —
> closes Phase 4 and brings the v2 distributed-runtime spec to
> completion across all seven phases.

This round adds a **NATS supercluster topology generator** and
canonical 2-cluster sample manifests for a meshed JetStream
deployment. Follows the same pattern proven by Phase 4 round 2
(KEDA scaler): generator + sample manifests + wiki + drift-guard
tests, with **no live cluster install** and **no edits to the
existing single-node `ci/manifests/nats/` deployment**.

The existing single-node NATS StatefulSet remains the default
`noetl k8s deploy` target. The supercluster lives in a separate
`ci/manifests/nats-supercluster/` directory and is applied
manually when an operator wants the multi-cluster topology.

## Why the manifests + generator split

NATS distinguishes two topologies:

- **Cluster** — 3+ NATS servers connected via a `cluster {}`
  block, sharing JetStream state via Raft consensus. Single
  account namespace, mutual `route` URLs between members.
- **Supercluster** — multiple clusters connected via NATS
  **gateway** connections (`gateway {}` block). Each cluster
  has its own JetStream state; gateways enable cross-cluster
  subject routing without shared Raft.

Phase 4 round 3 ships the **supercluster** shape (the larger
of the two) because:

1. It's the production-target topology the user laid out
   ("workers route to KEDA-managed NATS supercluster").
2. A single 3-node cluster is a degenerate case of the
   supercluster generator (one cluster, no gateways).
3. The locality-by-URN routing requires cross-cluster
   gateways; intra-cluster Raft alone doesn't enable
   region-aware subject routing.

## What this round delivers

1. `noetl/core/runtime/nats_topology.py` — new module:
   - `ClusterTopology` frozen dataclass — `cluster_id`,
     `cluster_size` (replicas), `host`, `peer_clusters` (other
     `ClusterTopology` entries for gateway URLs), optional
     locality fields (`region`, `zone`).
   - `SuperclusterTopology` frozen dataclass — list of
     `ClusterTopology` entries with a `validate()` method that
     catches duplicate cluster IDs, gateway-loop self-refs,
     etc.
   - `build_nats_conf(cluster, *, supercluster=None) -> str` —
     produces the `nats.conf` body for one cluster. Includes
     `port`, `http_port`, `jetstream {}` (with cluster name +
     domain), `cluster {}` (routes to siblings within the same
     cluster), `gateway {}` (gateways to peer clusters), and
     the existing `accounts` block (preserved verbatim from
     `ci/manifests/nats/nats.yaml`).
   - `build_cluster_manifests(cluster, *, supercluster, namespace) -> list[dict]`
     — produces a list of Kubernetes manifests (ConfigMap +
     StatefulSet + Service) for one cluster. Returns plain
     dicts so callers can `yaml.safe_dump` or apply via the
     Kubernetes Python client.
   - `dump_manifests_yaml(manifests) -> str` — render a list of
     manifests to a single YAML stream (`---`-separated) with
     stable key order.
   - URN-driven defaults: when a `ClusterTopology` is built
     with a `cluster_urn=...` kwarg, the cluster name + JetStream
     domain derive from the URN's NATS-safe subject form (round
     1's `to_nats_subject()`).

2. `ci/manifests/nats-supercluster/` — new directory:
   - `README.md` — design + manual install + verification
     commands (`nats server gateway`, `nats stream cluster-info`,
     `nats account info`).
   - `cluster-a.yaml`, `cluster-b.yaml` — two canonical 3-node
     clusters with mutual gateway connections. Each file
     contains the full ConfigMap + StatefulSet + Service for
     one cluster.
   - `namespace.yaml` — `nats-supercluster` namespace (kept
     separate from the existing `nats` namespace so both
     topologies can coexist during evaluation).

3. `tests/core/runtime/test_nats_topology.py` — unit tests:
   - `ClusterTopology` / `SuperclusterTopology` validation
     (duplicate cluster IDs, gateway-loop guard, replicas >= 1,
     URN-derived cluster_id).
   - `build_nats_conf` block-by-block assertions for cluster
     name, JetStream domain, cluster routes, gateway URLs.
   - `build_cluster_manifests` schema walk (ConfigMap data,
     StatefulSet `replicas`, Service port shape).
   - YAML round-trip + key-order preservation.
   - Sample-manifest drift guards (same pattern as
     `test_sample_manifest_matches_generator_output` from
     round 2): `cluster-a.yaml` and `cluster-b.yaml` each
     compared against the generator output for their
     documented call.
   - URN → cluster name derivation: a URN
     `noetl://tenant/acme/org/research/region/us-east1/cluster/east`
     produces a topology with cluster_id `east` (the trailing
     segment) and JetStream domain
     `noetl_tenant_acme_org_research_region_us-east1_cluster_east`.

4. Wiki page `noetl/core/runtime/nats_supercluster.md` — new
   dedicated page. Covers: topology design (cluster vs.
   supercluster), generator API, sample manifests, manual
   install commands, verification, tuning (gateway tls /
   compression / advertise URLs), out-of-phase follow-ups.

5. Update wiki `noetl/core/messaging.md` — add a short
   "Multi-cluster topology" subsection cross-linking to the
   new page. Note that the Python client (`NATSCommandPublisher`
   etc.) doesn't yet do cluster-aware routing — that's
   out-of-phase work.

6. Update wiki `noetl/core/runtime/keda.md` — note that the
   `nats_account` field defaults to `$G` and per-tenant
   accounts wait for the catalog-era work (after Phase 4
   closes).

7. Update wiki `Home.md` and `_Sidebar.md` to list the new
   `nats_supercluster` page.

## What this round does NOT do

- **No edits to the existing `ci/manifests/nats/nats.yaml`.**
  The single-node deployment stays unchanged.
- **No live cluster install.** Per the round-2 pattern,
  KEDA-style manual one-off via the README + wiki.
- **No client-side rewiring.** `NATSCommandPublisher`,
  `NATSCommandSubscriber`, and the worker config keep
  pointing at the existing single-cluster endpoint. A future
  out-of-phase round adds cluster-aware client routing once
  the catalog exists.
- **No per-tenant accounts.** The default `NOETL` account
  from the existing manifest is preserved in the new clusters.
  Per-tenant accounts (and the matching KEDA `nats_account`
  field wiring) are out-of-phase work.
- **No cross-cluster stream mirror / source config.** The
  generator emits the gateway topology so cross-cluster
  routing **can** happen, but no stream is configured to use
  it. That's downstream catalog-era work too.
- **No noetl Python module imports of the new generator.**
  Same hermetic shape as round 2: generator stands alone,
  callers (catalog work, etc.) integrate later.

## Background

### Verified existing surface (on origin/main @ f574b328)

- `ci/manifests/nats/nats.yaml` — single-node `nats`
  StatefulSet in namespace `nats`. ConfigMap `nats-config`
  carries `port 4222`, `http_port 8222`, JetStream config,
  and the `$SYS`/`NOETL` accounts block.
- `ci/manifests/nats/values.yaml` — **dead reference file**
  (has the official Helm chart's cluster config but isn't
  wired up; typo `enabled: ture` confirms it's not used).
  Round 3 leaves it alone.
- `ci/manifests/nats/README.md` — current single-node docs.
- `noetl/core/runtime/keda.py` — round 2 module. The
  supercluster generator follows the same shape (dataclass +
  builder + YAML dumper + URN-aware defaults).
- `noetl/core/resource_locator.py` — round 1 module.
  `to_nats_subject()` is the canonical name-derivation
  helper.

### NATS supercluster — protocol reference

A supercluster member needs three config blocks beyond the
basics:

```hocon
# Intra-cluster routes (Raft for JetStream replication)
cluster {
  name: "cluster-a"
  port: 6222
  routes: [
    nats-route://nats-cluster-a-0.nats-cluster-a.nats-supercluster.svc.cluster.local:6222
    nats-route://nats-cluster-a-1.nats-cluster-a.nats-supercluster.svc.cluster.local:6222
    nats-route://nats-cluster-a-2.nats-cluster-a.nats-supercluster.svc.cluster.local:6222
  ]
}

# Inter-cluster gateways
gateway {
  name: "cluster-a"
  port: 7222
  gateways: [
    { name: "cluster-b", urls: ["nats://nats-cluster-b.nats-supercluster.svc.cluster.local:7222"] }
  ]
}

# JetStream with a domain (required for supercluster-aware streams)
jetstream {
  store_dir: /data/jetstream
  domain: cluster_a
  max_memory_store: 1GB
  max_file_store: 5GB
}
```

Reference: https://docs.nats.io/running-a-nats-service/configuration/clustering
and https://docs.nats.io/running-a-nats-service/configuration/gateways.

### Sample topology used for the committed manifests

Two clusters, each 3 replicas, mutual gateways:

| Cluster | URN | Replicas | JetStream domain |
|---|---|---|---|
| cluster-a | `noetl://tenant/default/org/default/region/us-east-1/cluster/cluster-a` | 3 | `cluster_a` |
| cluster-b | `noetl://tenant/default/org/default/region/us-west-2/cluster/cluster-b` | 3 | `cluster_b` |

Each cluster is a StatefulSet named `nats-cluster-<id>` in
namespace `nats-supercluster` with three pods. Gateway URLs
point at the headless service of the peer cluster.

The choice of two regions (`us-east-1` / `us-west-2`) is
illustrative; the manifests don't depend on any specific cloud
provider.

## Phases

### Phase A — drift check (no remote writes)

1. Re-verify `ci/manifests/nats/nats.yaml`,
   `ci/manifests/nats/README.md`,
   `noetl/core/runtime/keda.py`,
   `noetl/core/resource_locator.py` on `origin/main`. Flag
   any drift since the Phase 4 round 2 close-out.
2. Confirm no existing `noetl/core/runtime/nats_topology*`
   module.
3. Confirm `ci/manifests/nats-supercluster/` does not exist
   yet.
4. Confirm `noetl/core/runtime/nats_supercluster.md` on the
   wiki does not exist.

### Phase B — implementation

5. **Generator module** —
   `noetl/core/runtime/nats_topology.py`:
   - Module docstring referencing Phase 4 round 3 + the
     supercluster-vs-cluster distinction + the
     "manifests-only, no client rewiring" scope.
   - Constants:
     - `DEFAULT_CLIENT_PORT = 4222`
     - `DEFAULT_MONITORING_PORT = 8222`
     - `DEFAULT_CLUSTER_PORT = 6222`
     - `DEFAULT_GATEWAY_PORT = 7222`
     - `DEFAULT_NAMESPACE = "nats-supercluster"`
     - `DEFAULT_JETSTREAM_STORE_DIR = "/data/jetstream"`
     - `DEFAULT_JETSTREAM_MAX_MEMORY = "1GB"`
     - `DEFAULT_JETSTREAM_MAX_FILE = "5GB"`
     - `DEFAULT_NATS_IMAGE = "nats:latest"`
   - `ClusterTopology` frozen dataclass:
     - `cluster_id: str` (required)
     - `cluster_size: int` (default 3 — JetStream's min for
       Raft is 3)
     - `host: str = "nats-cluster-{cluster_id}"` (StatefulSet
       name shape)
     - `region: Optional[str] = None`
     - `zone: Optional[str] = None`
     - `cluster_urn: Optional[str] = None`
     - `jetstream_domain: Optional[str] = None` (derived from
       URN if absent and URN provided; falls back to
       `cluster_id` with `-` → `_`)
   - `SuperclusterTopology` frozen dataclass:
     - `clusters: tuple[ClusterTopology, ...]`
     - `namespace: str = DEFAULT_NAMESPACE`
     - `image: str = DEFAULT_NATS_IMAGE`
     - `validate()` method — checks cluster_id uniqueness,
       cluster_size >= 1, no self-reference issues.
   - `_jetstream_domain_for(cluster: ClusterTopology) -> str`
     — derivation rule.
   - `_route_url(cluster, replica_index, namespace) -> str` —
     `nats-route://nats-cluster-<id>-<idx>.nats-cluster-<id>.<ns>.svc.cluster.local:6222`.
   - `_gateway_url(peer, namespace) -> str` —
     `nats://nats-cluster-<peer_id>.<ns>.svc.cluster.local:7222`.
   - `build_nats_conf(cluster, *, supercluster) -> str` —
     produces the `nats.conf` body via plain string templating
     (HOCON-ish format; no third-party templater required).
     Includes:
     - `port` / `http_port`
     - `jetstream { ... domain: ... }`
     - `cluster { name, port, routes: [...] }` (other replicas
       within the same cluster)
     - `gateway { name, port, gateways: [{name, urls}, ...] }`
       (one entry per peer cluster)
     - `accounts { ... }` (verbatim from the existing
       single-node `nats.conf`; `$SYS` + `NOETL` accounts)
   - `build_cluster_manifests(cluster, *, supercluster) -> list[dict]`:
     - `ConfigMap` named `nats-cluster-<id>-config` carrying
       the rendered `nats.conf`.
     - `StatefulSet` named `nats-cluster-<id>` with
       `replicas: cluster.cluster_size`, headless Service name
       matching, three ports (client/monitoring/cluster +
       gateway), `args: ["-c", "/etc/nats/nats.conf"]`, livens
       + readiness probes mirroring the existing manifest.
     - `Service` (headless, `clusterIP: None`) named
       `nats-cluster-<id>` exposing all four ports.
   - `dump_manifests_yaml(manifests) -> str` —
     `yaml.safe_dump_all([m for m in manifests], sort_keys=False)`.
   - `__all__` exports every public symbol.

6. **Sample manifests** —
   `ci/manifests/nats-supercluster/`:
   - `namespace.yaml` — plain `kind: Namespace` for
     `nats-supercluster`.
   - `cluster-a.yaml` — generated by:
     ```python
     cluster_a = ClusterTopology(
         cluster_id="cluster-a", cluster_size=3, region="us-east-1",
         cluster_urn="noetl://tenant/default/org/default/region/us-east-1/cluster/cluster-a",
     )
     cluster_b = ClusterTopology(
         cluster_id="cluster-b", cluster_size=3, region="us-west-2",
         cluster_urn="noetl://tenant/default/org/default/region/us-west-2/cluster/cluster-b",
     )
     topo = SuperclusterTopology(clusters=(cluster_a, cluster_b))
     print(dump_manifests_yaml(build_cluster_manifests(cluster_a, supercluster=topo)))
     ```
   - `cluster-b.yaml` — symmetric, generated by calling
     `build_cluster_manifests(cluster_b, supercluster=topo)`.
   - Both files have a generator-call header comment matching
     the round-2 pattern.

7. **Manifest README** —
   `ci/manifests/nats-supercluster/README.md`:
   - Topology design summary.
   - Apply commands:
     ```
     kubectl apply -f ci/manifests/nats-supercluster/namespace.yaml
     kubectl apply -f ci/manifests/nats-supercluster/cluster-a.yaml
     kubectl apply -f ci/manifests/nats-supercluster/cluster-b.yaml
     ```
   - Verification:
     ```
     kubectl get statefulset -n nats-supercluster
     kubectl get pods -n nats-supercluster -l 'app in (nats-cluster-a, nats-cluster-b)'
     # Inside any pod:
     nats server gateway list
     nats stream cluster-info <stream-name>
     ```
   - Explicit warning: **do not delete `ci/manifests/nats/`** —
     the supercluster does not replace the existing single-node
     deployment in this round.
   - Regeneration recipe (the Python snippet above).

### Phase C — tests

8. New file `tests/core/runtime/test_nats_topology.py`:
   - `test_cluster_topology_jetstream_domain_default_from_id`
   - `test_cluster_topology_jetstream_domain_from_urn` — URN
     with a `cluster/<id>` segment drives the domain via
     `to_nats_subject()`.
   - `test_cluster_topology_explicit_domain_wins_over_urn`
   - `test_supercluster_validate_rejects_duplicate_cluster_ids`
   - `test_supercluster_validate_rejects_empty_clusters`
   - `test_supercluster_validate_rejects_cluster_size_zero`
   - `test_build_nats_conf_includes_cluster_routes` — N-1
     `nats-route://` entries pointing at other replicas of the
     same cluster (the StatefulSet pod ordinals 0..N-1, minus
     self... actually NATS de-dups self-routes so include all
     N and let NATS handle it — confirm by reading the actual
     `nats-server` docs in implementation).
   - `test_build_nats_conf_includes_gateway_entries` — one
     `{name, urls}` per peer cluster.
   - `test_build_nats_conf_preserves_accounts_block` — `$SYS`
     and `NOETL` accounts present (string match).
   - `test_build_nats_conf_jetstream_domain_present`
   - `test_build_cluster_manifests_emits_configmap_statefulset_service`
     — at least one of each kind, in that order.
   - `test_build_cluster_manifests_statefulset_replicas_match_cluster_size`
   - `test_build_cluster_manifests_configmap_carries_nats_conf`
     — ConfigMap `.data["nats.conf"]` equals
     `build_nats_conf(...)` output.
   - `test_build_cluster_manifests_service_is_headless` —
     `clusterIP: None`.
   - `test_dump_manifests_yaml_separates_with_yaml_docs` —
     `---` markers between docs; `yaml.safe_load_all` recovers
     identical list.
   - `test_sample_cluster_a_yaml_matches_generator_output` —
     drift guard (same pattern as round 2's KEDA test).
   - `test_sample_cluster_b_yaml_matches_generator_output` —
     drift guard.
   - `test_sample_namespace_yaml_matches_expected_shape` —
     drift guard for the namespace manifest.
   - URN-driven cluster_id: a URN with `cluster/east-1` →
     cluster_id "east-1" (URN-aware constructor helper, if
     added; otherwise document as caller's responsibility).

9. Run:
   ```
   .venv/bin/python -m pytest tests/core/runtime/test_nats_topology.py -q
   .venv/bin/python -m pytest tests/core/runtime/ tests/core/test_resource_locator.py tests/core/test_runtime_topology.py -q
   ```
   All green.

### Phase D — wiki update

10. Create `repos/noetl-wiki/noetl/core/runtime/nats_supercluster.md`.
    Sections:
    - **Purpose** — multi-cluster NATS topology so JetStream
      streams + workers can be regional + tenant-partitioned.
    - **Cluster vs. supercluster** — short explanation of the
      two NATS concepts, when to use which.
    - **`ClusterTopology` + `SuperclusterTopology`** — full
      field tables.
    - **Generated config** — annotated `nats.conf` snippet
      example.
    - **Sample manifests** — link to the committed
      `cluster-a.yaml` / `cluster-b.yaml` with the generator
      snippet that produces them.
    - **Install + verify** — `kubectl apply` recipe + `nats
      server gateway list`, `nats stream cluster-info`,
      `nats account info` commands.
    - **Tuning** — `cluster_size` (Raft min 3), gateway TLS
      considerations, JetStream `max_file_store` per cluster,
      cluster vs. supercluster trade-offs.
    - **What this round does NOT do** — bullet list mirroring
      the prompt: no client rewiring, no per-tenant accounts,
      no cross-cluster mirror/source streams.
    - **Related** — cross-links to
      [Resource Locator](resource_locator),
      [KEDA Scaler](keda),
      [Messaging](messaging),
      [Runtime Topology](topology).

11. Update `repos/noetl-wiki/noetl/core/messaging.md`:
    - Add a short "Multi-cluster topology" subsection right
      after the existing high-level description. Cross-link to
      the new page. Note the client-side rewiring is
      out-of-phase.

12. Update `repos/noetl-wiki/noetl/core/runtime/keda.md`:
    - Add a one-paragraph note under "Tuning" explaining that
      `nats_account` defaults to `$G` and that per-tenant
      accounts wait for the catalog-era work (out-of-phase).

13. Update `repos/noetl-wiki/Home.md` — new row under
    `noetl/core/runtime/` for **NATS Supercluster**.

14. Update `repos/noetl-wiki/_Sidebar.md` — list **NATS
    Supercluster** under the runtime grouping.

15. Commit + push wiki.

### Phase E — verify locally

16. Pytest is the only required gate this round. Already
    covered by Phase C.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 4 nats`.***

17. Push branch `kadyapam/phase4-nats-supercluster`, open
    noetl PR titled `feat(runtime): NATS supercluster topology generator + sample manifests`.
18. PR body lists:
    - Summary + the architectural context from the user's
      direction.
    - Why supercluster (not just cluster).
    - **The Phase 4 close-out call-out** — this PR completes
      v2 distributed-runtime spec across all seven phases.
    - Out-of-scope items.
    - Test plan.
    - Manual cluster-side install commands.
    - Paired wiki commit pointer.
    - Follow-up list (per-tenant accounts, client routing,
      cross-cluster stream replication, catalog-driven
      regional routing).
19. Wait for CI / human review.
20. Merge with `--admin --merge --delete-branch`.
21. Bump ai-meta pointers (noetl + noetl-wiki).
22. Archive handoff.
23. **Drop a memory entry summarizing v2 spec Phase 4
    completion (rounds 1–3) AND the broader v2 spec
    completion across all phases (0–6).**

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed` (the latter inherits the
supercluster apply commands).

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  says so. Phase F is the only step that pushes, gated by
  `merge phase 4 nats`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — Phase D ships a
  new wiki page for the new `noetl/core/runtime/nats_topology.py`
  module (rule 1).
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the
  report with `status: blocked`.
- **No live NATS supercluster install.** Manual escalation
  step only.
- **No edits to `ci/manifests/nats/nats.yaml`.** The
  existing single-node deployment is preserved.
- **No client-side rewiring.** `NATSCommandPublisher`,
  `NATSCommandSubscriber`, and the worker config keep
  pointing at the existing single-cluster endpoint.
- **No per-tenant accounts.** Future round.
- **No cross-cluster stream mirror / source config.** Future
  round.
- **Sample-manifest drift guards required.** Same shape as
  round 2's KEDA test — load the committed YAML, compare
  structurally to the generator output for the documented
  call.
