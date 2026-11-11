# RFC: a distributed, content-addressed playbook catalog

Tracks [noetl/ai-meta#548](https://github.com/noetl/ai-meta/issues/548). Status: **all three phases built and kind-validated; PRs open (§11).**
Written 2026-11-10 against `main` of server `acfa53c`, cli `6e7ed57`, worker `d4b9940`, tools `dd00c05`,
ehdb `210531d`, ehgraph `f200516`.

Related: [`ehdb-catalog-relation.md`](ehdb-catalog-relation.md) (the catalog as an EHDB fold),
[`interop-topology-and-ai-mcp-playbooks.md`](interop-topology-and-ai-mcp-playbooks.md) and
[`interop-missing-tools-build-plan.md`](interop-missing-tools-build-plan.md) (item 9, the instance registry),
[`dsl-knowledge-base.md`](dsl-knowledge-base.md) (the `sha256:` sorted-key-JSON digest),
[`ehdb-topology-membership.md`](ehdb-topology-membership.md) (cross-cluster reads), ai-meta#427 (EHDB-backed
catalog), ai-meta#455 (EHDB as registry).

## 1. What we want

1. **Distributed discovery.** When a playbook is registered in one cluster, another cluster can find it from a
   reference and execute it.
2. **Many source backends.** A playbook can live in an object-store bucket (GCS, S3, Azure Blob, MinIO), in a
   database table, in EHDB, or in a cluster's catalog. A reference resolves against any of them.
3. **A cheap discovery mechanism.** "Might cluster X hold playbook Y?" must be answerable without asking X. Direct
   URI fetch must work when the reference already says where the playbook is.
4. **No duplicated content.** One stored body per digest; many references to where it came from.
5. **Execution pinning.** An execution resolves its playbook once, to a version and a digest, and keeps it for its
   whole life, sub-playbooks included. A registry change mid-flight does not change a running execution. An
   explicit, opt-in hot-reload exists for workloads that need it.
6. **WASM.** A deterministic subset of a playbook can be compiled to a WASM module and hot-reloaded.

## 2. What exists today (and what it gets wrong for this)

| Fact | Where | Consequence |
|---|---|---|
| The catalog is Postgres `noetl.catalog`, one immutable row per `(path, version)`; `version` is `MAX(version)+1` per path, a `smallint` | `server/src/db/queries/catalog.rs:37-93`, `db/ddl/postgres/schema_ddl.sql:42-53` | Identity is a name and a counter. Registering the same bytes twice makes two versions. |
| No storage trait; execute and events read `noetl.catalog` with raw `sqlx` | `services/catalog.rs:44`, `handlers/execute.rs:636-778` | A new backend means a seam, not a config switch. |
| A content hash exists only in shadow features: `sha256_hex(raw yaml bytes)` | `handlers/catalog_snapshot.rs:136`, `catalog_log.rs:127` | Nothing indexes content. Whitespace or comment changes change the hash. |
| A content digest exists for the DSL schema: `sha256:` over sorted-key JSON | `orchestrate-core/src/dsl.rs:179-220` | The right primitive; it is not applied to playbooks. |
| Execute resolves a path to its **latest** version, then every orchestrator pass re-reads content **by `catalog_id`** | `execute.rs:693-697`; `events.rs:3349,3873,4641` | The root execution is pinned by id already (rows are immutable). |
| A sub-playbook call (`kind: playbook`) POSTs `/api/execute` with `path`/`version`/`catalog_id`; `ExecuteRequest` has **no `version` field**, so a declared version is **silently dropped** and the child gets latest-at-call-time | `tools/src/tools/playbook.rs:308-360`, `execute.rs:16-55` | **The pinning bug.** A child registered mid-flight changes a running execution. |
| Item 9: a per-control-plane, in-memory instance registry with ML-DSA-87 signed requests, an allowlist gate and a pull inbox. Instances advertise `Capabilities { runtime_kind, playbooks: [glob], endpoint, … }` (`deny_unknown_fields`). Servers never call each other. | `server/src/instances/{registry,gate,identity,tasks}.rs` | The peer substrate exists, but has no room for a catalog advert and no server-side peer client. |
| A reviewed bloom filter: `ehdb_l0::Bloom`, `Mixed` scheme (SplitMix64 probes), serde `BloomWire`, ~1% FPR, ≤256 Ki bits | `ehdb/crates/ehdb-l0/src/bloom.rs` | Reuse it; the server already depends on `ehdb-l0`. Use `Mixed` explicitly, never `Legacy` (the retention-floor collapse, ai-meta#517). |
| The worker runs WASM plug-ins with wasmtime 27, cached by `PluginKey { path, version, digest }`; the server seeds and serves module bytes; "hot reload by re-seed" (same version, new digest) already works for `system/orchestrate` | `worker/src/plugin.rs:56,267,389`; `server/src/system_plugins.rs:11-16` | The hot-reload half of requirement 6 exists. Missing: a compiler and a purity check. |
| orchestrate-core already builds for `wasm32-unknown-unknown` with zero imports (the off-server drive) | `server/plugins/orchestrate`, `server/Dockerfile:41-54` | The engine itself runs in WASM today. |

## 3. Model: the digest is the identity, everything else is a reference

```
            names (mutable pointers)                identity (immutable)          sources (where to fetch)
  ┌────────────────────────────────────┐        ┌────────────────────────┐     ┌──────────────────────────────┐
  │ catalog row  path=a/b  version=3 ──┼──────▶ │ sha256:9f2c…  (body)   │ ◀───┤ noetl://ni-…/a/b@3          │
  │ catalog row  path=x/y  version=1 ──┼──────▶ │                        │ ◀───┤ gs://bucket/a/b.yaml         │
  └────────────────────────────────────┘        └────────────────────────┘ ◀───┤ s3://…  az://…  db://…  ehdb:// │
                                                                                 └──────────────────────────────┘
```

### 3.1 The playbook digest

`playbook_digest(yaml) = dsl::digest(yaml → JSON value)`: parse the YAML, convert to a JSON value, serialise with
object keys sorted at every level, SHA-256, prefix `sha256:`. This is the DSL-KB function unchanged.

- It is **semantic**: comments, key order, quoting and indentation do not change it; any change to a value does.
  Two registrations of the same playbook with different formatting share one identity.
- It is **not** `content_sha256`. The shadow snapshot/log keep hashing raw bytes (their job is "are these the bytes
  that ran"); the catalog keeps both. A source fetch is verified against the digest, so a re-formatted copy in a
  bucket still verifies.
- YAML features with no JSON form (non-string keys, tags) are rejected at digest time, which is at register time.

### 3.2 Dedup rules

1. **One body per digest.** `catalog_blob(digest PK, content, bytes, first_catalog_id)`. A second registration of
   the same digest under any path stores no second body.
2. **Same path, same digest as that path's latest version: no new version.** Register returns the existing
   `(catalog_id, version)` with `deduplicated: true`. This stops version churn from re-applying the same file (CI,
   `noetl catalog register` loops). A digest equal to an *older* version is a real roll-back and does get a new
   version: the name history matters and is preserved.
3. **Different path, same digest:** a new name row pointing at the existing body. Names are cheap; bodies are not.
4. **Sources are a set per digest.** `catalog_source(digest, uri, origin, added_at, verified_at)`, primary key
   `(digest, uri)`. Every registration records `noetl://<instance>/<path>@<version>`. A caller can add a declared
   source (`gs://…`) and a fetch that verifies sets `verified_at`.
5. **When duplication is unavoidable** (a peer's copy imported for execution, a WASM artifact compiled from a body),
   the copy carries the source digest and the reference it came from. Nothing is ever stored without its provenance.

**Phase 1 honesty note.** `noetl.catalog.content` keeps a copy of the body on every row, because every existing
reader (execute, the drive, the MCP server, the UI) reads that column. Phase 1 dedups **identity, versions and
sources**; it does not yet remove the per-row copy. Removing it means moving readers to the blob table (or to the
EHDB fold of ai-meta#427), which is a later step and listed in §9.

### 3.3 References and URI schemes

One grammar, parsed by `orchestrate-core::catalog::PlaybookRef` (pure, also used by the CLI and the WASM runner):

| Form | Meaning | Resolver |
|---|---|---|
| `a/b` | latest version of path `a/b` (or the pinned one, §5) | local catalog |
| `a/b@3` | exact version | local catalog |
| `a/b@latest` | latest, explicitly — never pinned | local catalog |
| `sha256:<64 hex>` | exactly this body, under any name | local blob, then peers |
| `a/b@sha256:<hex>` | this name, and it must have this body | local catalog |
| `noetl://<ni-id>/a/b@3` | that cluster's catalog | peer (§4) |
| `gs://bucket/key.yaml`, `s3://…`, `az://container/key`, `minio+http://host:port/bucket/key` | an object | object store |
| `https://host/path.yaml` | a URL | HTTP |
| `db://<credential-alias>/<schema>.<table>?path=a/b&version=3` | a row in an external table with `content` | database |
| `ehdb://catalog/<catalog_id>` | the EHDB catalog tier record | EHDB |
| `file:///abs/path.yaml` | local file (CLI/daemon only) | filesystem |

Any URI form may carry `#sha256:<hex>`. With it, the fetched body must match or the resolve fails. Without it, the
fetched body's digest becomes the identity and is reported back, and **the execution pins that digest** — so a
bucket object rewritten mid-run still cannot change the run.

Credentials are never URI userinfo: the parser refuses `user:pass@`. **As built (Phase 2), object stores use ambient
platform identity only.** That means workload identity for `gs://` in GKE, and the standard `AWS_*` / `AZURE_*` environment for
`s3://`, `az://` and MinIO. Keychain-alias credentials per source (`?credential=<alias>`) are TARGET (§9).

## 4. Discovery across clusters

### 4.1 Three ways to find a playbook, cheapest first

1. **Local**: the catalog and blob table on this server.
2. **Direct**: the reference names a source (`gs://`, `noetl://ni-B/…`, `https://`). Fetch it, verify, import.
3. **Probe**: the reference is a name or a digest that is not local. Ask each known peer's **bloom filter** whether it
   might hold it; query only the peers that say "maybe", freshest first; the first verified answer wins.

A registry (a central index of everything everywhere) was considered and rejected for now: it is a second copy of
every catalog that must be kept consistent, i.e. a representation that drifts (`agents/rules/representation-drift.md`).
Blooms are derived, cheap to recompute and wrong only in the safe direction (a false positive costs one query; there
are no false negatives).

### 4.2 The bloom advertisement

- Each server builds `ehdb_l0::Bloom::for_expected_in(n, BloomScheme::Mixed)` over three key families:
  `d:<digest>`, `p:<path>`, `v:<path>@<version>`. Archived rows are excluded.
- It is rebuilt on a timer (`NOETL_CATALOG_ADVERT_SECS`, default 60) and on register. It carries a `generation`
  (monotonic) and `entries`.
- At ~1% FPR the 256 Ki-bit cap holds ~27k keys, i.e. ~9k playbook versions with three keys each. Past that the
  advert switches to `p:`+`d:` only and says so (`families: ["p","d"]`), rather than silently saturating.
- A probe for `a/b` tests `p:a/b`; for `a/b@3` tests `v:a/b@3`; for a digest tests `d:<digest>`.

### 4.3 Riding item 9

Item 9 already gives identity (ML-DSA-87, `ni-<16 bytes of sha256(pk)>`), a trust gate (allowlist, audience, skew,
nonce replay) and liveness (registration as heartbeat, TTL). The catalog reuses all three:

- **A cluster is an instance.** A server that takes part gets an instance key (`NOETL_CATALOG_PEER_KEY_FILE`, a
  secret: GSM via the Secret Store CSI driver in GKE, a k8s Secret in kind) and registers itself with each peer
  control plane in `NOETL_CATALOG_PEERS` as `runtime_kind: distributed`, `endpoint: <its base URL>`.
- **The advert rides the registration.** `Capabilities` gains one typed, bounded, optional field:
  `catalog: { scheme: 2, generation, entries, families, bloom: BloomWire }` (≤ 32 KiB; the envelope cap is 256 KiB).
  `deny_unknown_fields` stays; an old server refuses the field, which is the correct failure.
- **The probe is a registry query.** Cluster A lists live `distributed` instances from its own registry, tests their
  blooms locally, and calls only the "maybe" ones.
- **The fetch is a signed call.** A calls B's `POST /api/catalog/peer/resolve` with a signed envelope (purpose
  `catalog.resolve`) under A's key. B admits it through the same item-9 gate (A must be in B's
  `NOETL_INSTANCE_TRUSTED_IDS`). Trust is mutual and explicit; there is no ambient peer trust.
- **Liveness is the registry's.** A peer whose registration expired is not probed.

### 4.4 Import and execute

- A verified fetch is **imported**: the body goes into the blob table (dedup by digest), a source row records
  `noetl://ni-B/a/b@3`, and a catalog row is created under the **namespaced path** `peer/<ni-B>/a/b` so an imported
  copy can never shadow a local `a/b`.
- Execution then proceeds locally on A's workers, pinned to the imported digest.
- Running the playbook *on B* instead is item 9's handoff (`/api/instances/tasks/submit`), which already exists for
  CLI instances; extending it to server instances is in §9.
- Phase 2 imports one playbook. The transitive closure (its `kind: playbook` children, resolved in B's namespace) is
  the next step: the pin carries a path-rewrite map for the imported scope (§9).

### 4.5 Security

- A peer is trusted by id, explicitly, on both sides. No id is invented for tests in prod.
- Peer resolve never returns credential rows (`kind: credential` is excluded from adverts and resolves).
- Imported bodies go through the same `registration_checks` as a local register: tool-kind gates, the inline-secret
  scan, the subscription check.
- Bloom adverts leak only "a key with this hash might exist". Path names are hashed; they are not listed.

## 5. Versioning and execution pinning

### 5.1 The pin

At `POST /api/execute`, after resolving the root, the server writes one **pin** for the execution:

```
execution_catalog_pin(
  execution_id PK, root_execution_id, parent_execution_id,
  catalog_id, path, version, digest,
  watermark BIGINT,          -- max(catalog_id) at the root's start
  reason TEXT,               -- exact | digest | pinned | latest | hot_reload | import
  policy JSONB,              -- the root's hot-reload policy, inherited
  created_at)
```

and the same values go into `playbook_started` as `catalog_pin` (the event log stays the source of truth; the
table is an index over it). The pin is **not** put in the context key `version`, because `WorkflowState`
re-exposes `version` into templates (`orchestrate-core/src/state.rs:1206`).

### 5.2 Why a watermark, not a timestamp

`catalog_id` is a database-generated snowflake (`noetl.snowflake_id()`): time-ordered from one clock. The root
records `watermark = max(catalog_id)` when it starts. Every later resolution in that execution tree uses
`WHERE path = $1 AND catalog_id <= $watermark ORDER BY version DESC`. That gives **"the catalog as it was when the
root started"**, exactly, with no clock comparison between server replicas and no need to know the child paths in
advance (a templated `path: "{{ workload.child }}"` pins too).

### 5.3 Resolution rules (in order)

| # | The request asks for | Result | `reason` |
|---|---|---|---|
| 1 | an exact version (`a/b@3`, `version: 3`) | that version | `exact` |
| 2 | a digest (`sha256:…`, `a/b@sha256:…`) | that body | `digest` |
| 3 | `a/b@latest` explicitly, **and** hot-reload is allowed for `a/b` (§6) | latest now | `hot_reload` |
| 4 | a path, inside an execution tree with a pin | latest at or below the watermark | `pinned` |
| 5 | a path, no pin (a root execution) | latest now, which becomes the watermark | `latest` |

Rule 3 without permission is an error, not a silent downgrade to rule 4: an author who wrote `@latest` and did not
get it would otherwise never know.

Archived rows: a version archived **before** the root started is invisible to the pin; one archived **after** stays
resolvable for the executions pinned to it. Archive never breaks a running execution.

### 5.4 The parent's own body

Already pinned: every orchestrator pass re-reads the body by `catalog_id` and rows are immutable. Phase 1 adds the
digest to the pin, so a replay or snapshot rebuild can verify it is folding against the same body.

### 5.5 The silent version drop

With `NOETL_CATALOG_PINNING=true`, `ExecuteRequest` accepts `version` (number or `"latest"`) and `digest`. With the
flag off the server behaves exactly as today, including ignoring `version`; flipping the flag is therefore a visible
behaviour change for any playbook that passes `version:` to a child, and is called out as such.

## 6. Hot reload: the controlled override

Some workloads want the opposite of pinning: a long `loop` that should pick up a fixed child playbook as soon as it
is registered, without restarting the loop.

**Shape.** The **root** playbook declares which children may float:

```yaml
metadata:
  path: ops/crawler
  catalog:
    hot_reload: ["ops/crawler/page_worker", "ops/crawler/parsers/*"]   # globs over child paths
```

and the call site asks for it: `path: ops/crawler/page_worker@latest` (or `version: latest`).

**Controls, all three required:**
1. Server flag `NOETL_CATALOG_HOT_RELOAD=true` (off by default; off means rule 3 is an error).
2. The root's `metadata.catalog.hot_reload` lists the path (a child cannot widen its parent's policy; the policy is
   copied into every pin of the tree).
3. The call explicitly says `@latest`.

**Record.** Each hot-reloaded call writes its own pin with `reason: hot_reload` and the digest it got, so the event
log shows exactly which iteration ran which version. Replay re-uses the recorded pins and never re-resolves.

**Granularity.** A reload happens only at a `kind: playbook` call boundary — in a loop, between iterations. A running
child is never swapped. Swapping the *running* playbook's own step graph mid-execution (the loop body itself) is
TARGET and deliberately not proposed for Phase 3: the state fold assumes one step graph per execution, and a new
version may have renamed steps the state already references. The safe form is to make the loop body a child.

## 7. WASM: compiling the deterministic subset

### 7.1 What is deterministic today

From the survey: the orchestrate-core engine (minijinja `when`/`set`/`loop in`, arc routing) is pure and already
compiles to `wasm32-unknown-unknown` with zero imports. Of the tool kinds only `noop` is pure. `rhai` is classified
non-side-effecting (`tools/src/registry.rs:169`) but its engine registers `http_*`, `timestamp`, `sleep` and
`random_*` (`tools/src/tools/rhai.rs:45+`), so it is **not** pure as shipped; a pure rhai profile is a prerequisite
for compiling rhai steps.

### 7.2 Design

- **Purity check** `catalog::purity(&Playbook) -> Pure | Impure { step, kind }`: every step is `noop` (later: pure
  rhai, pure `transform`), no `kind: playbook`, no external-I/O kinds, loops only over in-memory collections.
- **Artifact.** A generic runner module (orchestrate-core + an in-WASM `noop` executor that renders `result`/`set`
  templates) plus a custom section `noetl.playbook` holding the sorted-key playbook JSON and `noetl.digest`. The
  compiler embeds and validates; it does not interpret the playbook. Identity of the artifact = sha256 of the module
  bytes; it records `compiled_from: <playbook digest>` (§3.2 rule 5).
- **ABI.** The plug-in ABI the worker already speaks: `memory`, `alloc(len)`, `run(ptr,len) -> (out_ptr<<32|len)`,
  JSON in (`{workload}`), JSON out (`{status, result, steps}`), zero imports.
- **Hot reload.** Publish the artifact as plug-in `compiled/<path>` with version = the playbook version and digest =
  module digest. The worker's existing `PluginKey` cache picks up a new digest on the next claim; the old module is
  evicted (`evict_other_versions`).
- **Limits.** The worker's `Engine::default()` has no fuel or epoch limit; a compiled playbook can contain a loop,
  so the host must set fuel. The prototype host does; the worker change is listed in §9.

### 7.3 What "compile" means at each stage

| Stage | Meaning | Status |
|---|---|---|
| 1 | Embed + validate: runner module + playbook section; purity checked at compile | **prototype (Phase 3)** |
| 2 | Pre-parse templates at compile time and store the parsed form, so the module skips minijinja parsing | TARGET |
| 3 | AOT: generate Rust from the step graph (templates → closures), compile to WASM | TARGET |
| 4 | Server routes a pure sub-graph of an otherwise impure playbook to `kind: wasm` automatically | TARGET |

## 8. Phased plan

| Phase | Delivers | Repo | Flags (all default off) | Tests |
|---|---|---|---|---|
| **1** | `orchestrate-core::catalog` (digest, refs, pin, resolver over a `CatalogView` trait); server tables `catalog_blob`, `catalog_digest`, `catalog_source`, `execution_catalog_pin`; dedup on register; `POST /api/catalog/resolve`, `GET /api/catalog/blob/{digest}`, `POST /api/catalog/sources`, `GET /api/catalog/pin/{execution_id}`; execute writes and honours pins; `ExecuteRequest.version`/`digest` | server | `NOETL_CATALOG_CAS`, `NOETL_CATALOG_PINNING` | unit (resolver, digest, refs), router tests over an in-memory view, Postgres-gated SQL tests, kind: child re-registered mid-flight does not change the running parent |
| **2** | bloom advert, server instance key + peer registration, `Capabilities.catalog`, signed `peer/resolve`, `POST /api/catalog/locate`, import under `peer/<id>/`, direct URI fetch (`https`, `gs`, `s3`/`az`/MinIO via the `object_store` crate, `noetl://`) | server (+ cli for the `Capabilities` mirror) | `NOETL_CATALOG_PEERS`, `NOETL_CATALOG_PEER_KEY_FILE`, `NOETL_CATALOG_URI_FETCH` | unit (bloom, URI parse), two server instances in kind: B registers, A locates by name and digest, imports, executes |
| **3** | hot-reload override wired + loop test; WASM purity check, runner, compiler, wasmtime host with fuel, hot-reload by digest | server (+ plugins) | `NOETL_CATALOG_HOT_RELOAD` | kind: loop picks up v2 mid-run only with all three controls; WASM: compile, load, run, swap digest, run again |

## 9. TARGET (not in these phases)

- Drop the per-row `noetl.catalog.content` copy; readers move to the blob table or the EHDB catalog fold (ai-meta#427).
- `db://` and `ehdb://` resolvers (Phase 2 parses them and refuses with "not implemented", by name).
- Transitive import of a peer playbook's children with a path-rewrite map in the pin.
- Remote execution on the peer (item-9 handoff to a server instance).
- Peer catalog nodes in ehgraph (`origin=catalog`, `held_by` edges), so topology queries can answer "where does X live".
- Worker fuel/epoch limits for WASM plug-ins; a pure rhai profile; template pre-parse and AOT (§7.3).
- `version` wider than `smallint` (the EHDB catalog relation already plans it).
- Gossip of adverts between peers instead of point-to-point registration (`ehdb-topology-membership.md`).

## 10. Open questions (resolved by the author unless noted)

1. **Digest of what?** Semantic (sorted-key JSON), not raw bytes. *Resolved* (§3.1).
2. **Same digest re-registered at the same path.** No new version. *Resolved* (§3.2 rule 2). This changes what
   `register` returns for repeated identical registrations when `NOETL_CATALOG_CAS` is on; the response carries
   `deduplicated: true`.
3. **Pin by timestamp or by id.** By `catalog_id` watermark. *Resolved* (§5.2).
4. **Imported path.** Namespaced `peer/<id>/<path>`. *Resolved* (§4.4). Revisit if users want transparent aliases.
5. **Bloom transport.** Inside the item-9 registration, not a separate gossip. *Resolved* (§4.3) — **owner review
   welcome**, since it extends `Capabilities` on both server and CLI.

## 11. As built (2026-11-10)

| Phase | PRs | Runtime | Tests |
|---|---|---|---|
| 1 | noetl/server#572, noetl/ops#371 | server (distributed); the core is pure and wasm32-clean | unit (core 15, service 3), Postgres-gated test against kind's DB, **kind 18/18** |
| 2 | noetl/server#573 (stacked on #572), noetl/ops#372 | server ↔ server (two control planes) | unit (advert, peer config, FPR, URI builds, key file), **kind 30/30** with two control planes, each with its own DB, key and trust list, plus an S3-API server |
| 3 | noetl/server#574 (stacked on #573), noetl/ops#373 | server + worker (`kind: wasm`); standalone wasmtime host | core purity tests, 4 native runner tests, `ci/hot_reload.sh` (compile ×2, impure refused, fuel-limited host), **kind 12/12** |

Divergences from the draft, decided while building:

- Imports from a fetched URI live under `peer/source/<path>`, not `source/<path>`. Every import is then under `peer/`, which adverts and peer answers already exclude.
- MinIO no longer publishes public images, so the S3 path was validated against Adobe S3Mock. `minio+http(s)://` means "S3 API at an explicit endpoint", whoever serves it.
- Phase 3's hot reload needed no server code beyond Phase 1. The playbook tool's `version` is numeric, so `@latest` travels in `path` (`PlaybookRef::from_request`).

### REAL vs TARGET by requirement

| # | Requirement | REAL (built, kind-validated) | TARGET |
|---|---|---|---|
| 1 | Distributed discovery | A finds a playbook only B registered, by name, version, digest or `noetl://<B>/…`, then imports it and **executes it on A**. An execute-by-path that misses locally does this automatically for roots. | Running on B instead (item-9 handoff to a server instance); transitive import of children; ehgraph `held_by` nodes |
| 2 | Multiple backends | Local catalog; peer catalogs; `minio+http(s)://`, `s3://`, `gs://`, `az://` via `object_store`. Only the S3 API was exercised in kind (S3Mock); `gs://` and `az://` are built but not run against real buckets. `https://` too. All gated by an allowlist that fails closed. | `db://` and `ehdb://` resolvers (parsed, refused by name); keychain-alias credentials per source |
| 3 | Discovery mechanism | A per-cluster Mixed bloom (`p:` / `v:` / `d:`) rides the item-9 registration. A probe tests blooms locally and queries only the peers that answer "maybe" (a miss queried 0). The fetch is a signed envelope through the item-9 gate. Direct URI resolution works when a reference names its source. | Gossip of adverts; a central registry (rejected for now, §4.1) |
| 4 | Dedup | One body per digest (`catalog_blob`); the same body re-registered at a path makes no version; an import is indexed by digest (a second locate by digest is local); every copy keeps its sources (`catalog_source`). | Dropping the per-row `noetl.catalog.content` copy (readers still use it) |
| 5 | Versioning + pinning + hot reload | The root's `catalog_id` watermark is pinned before `playbook_started`, and every sub-playbook resolves inside it. In kind, a child registered mid-flight did not reach the running tree (and the control showed it did without the flag). `version`/`digest` are honoured. Hot reload works at call boundaries with three controls; in kind a loop moved v1 → v2 mid-run, and was refused without the policy. | Swapping the running playbook's own step graph mid-execution (deliberately not proposed) |
| 6 | WASM | Prototype: purity check, compile-time refusal of impure playbooks, a module with zero imports that drives orchestrate-core to completion, digest export equal to the catalog digest, hot reload by digest in a fuel-limited host. It **ran on the real worker** via `kind: wasm` and hot-reloaded there (50 → 500). | Worker fuel/epoch limits (the worker host has none, so this blocks real use); pure rhai and pipelines; template pre-parse and AOT codegen; auto-routing pure sub-graphs; a compile endpoint |

None of the flags is set in any prod manifest.
