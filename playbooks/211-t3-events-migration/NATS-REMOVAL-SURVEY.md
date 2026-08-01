# NATS dead-code removal — liveness survey

Done **before** deleting anything, because `NATS_FILTER_SUBJECT` already proved
that a NATS *name* is not evidence of a NATS *dependency*. Surveyed against
`origin/main` of each repo on 2026-08-01.

## Verdicts

### KEEP — NATS-named but on a live EHDB path

| Symbol | Repo | Why it is live |
| :-- | :-- | :-- |
| `segment_from_filter` | worker `src/nats/source.rs` | Derives the **EHDB** pool from the filter subject. Unsetting its input already collapsed the system pool onto `commands.shared.>` (#218). |
| `CommandNotification` | worker `src/nats/subscriber.rs` | The command payload type. The EHDB claim path decodes into it. |
| `claim_outcome` | worker `src/nats/source.rs` | Shared claim → `ClaimOutcome` logic. `EhdbCommandSource` calls it. |
| `config.nats.session_bucket` / `request_bucket` / `*_ttl_secs` | gateway `src/config.rs` | **Bucket names and TTLs for the EHDB KV store.** `SessionCache::with_ehdb` and `RequestStore::with_ehdb` read them. Only `config.nats.url` is dead. |

These get **moved/renamed**, never deleted.

### REMOVE — genuinely unreachable

| Thing | Repo | Evidence |
| :-- | :-- | :-- |
| `NatsSubscriber`, `NatsCommandSource`, `NatsAckHandle` | worker | Only reachable from `WorkerCommandSource::Nats`, and `NOETL_COMMAND_BUS=ehdb` everywhere. |
| `lag_poller` | worker | Already a no-op: it early-returns because `nats_subscriber()` is `None` on the EHDB bus. A timer spinning every 5 s to do nothing. |
| `ConsumerLag` | worker | Only consumed by `lag_poller`. |
| NATS drain in `state_builder` | worker | Replaced by the EHDB WAL drain (#217). |
| NATS source in materializers | worker | Replaced by `MaterializerFeed` (#212). |
| `EventStreamPublisher`, `NatsPublisher` | server | `NOETL_EVENT_BUS=ehdb`; `has_event_transport` no longer consults NATS. |
| `state.nats`, `config.nats_url` | server | Only readers left are the health field and `ReplicaCoherence::NatsKv`. |
| `ReplicaCoherence::NatsKv` | server | `NOETL_REPLICA_COHERENCE` unset in prod → `Local`, and the server runs **1 replica**. |
| `start_nats_listener`, `src/nats.rs`, NATS halves of `session_cache`/`request_store` | gateway | The call site went in #35; the functions are now unreferenced. |
| `nats` tool kind + `source/nats.rs` | tools | See the caveat below. |
| `async_nats` dependency | all four | Once the above go. |

### KEEP — not code

`nats-dr/` is the disaster-recovery IaC (stream/consumer/KV definitions + k8s
manifests). Explicitly retained.

## The one caveat that needs stating

**Five catalog playbooks still declare `kind: nats`:**

- `api_integration/auth0/auth0_login` (v102)
- `api_integration/auth0/auth0_login_optimized` (v3)
- `api_integration/auth0/auth0_validate_session` (v87)
- `test_nats_kv` (v2) and `prod-e2e-.../test_nats_kv` (v1)

They are **already non-functional** — there is no NATS server to connect to, so
those steps fail today regardless. Removing the tool kind does not break
anything that currently works; it turns a runtime connection failure into an
earlier, clearer "unknown tool kind".

They are also **not executed**: all three auth flows run on their sync
fast-paths (`NOETL_AUTH_SYNC=true`, `NOETL_AUTHZ_SYNC=true`), which never
dispatch a playbook.

**The consequence to be explicit about:** if someone later turns those sync
flags off, login falls back to the playbook path, which will now fail on the
missing tool kind. That is a *louder* failure than the NATS timeout it would
otherwise hit, but it is a real behavioural note. The auth playbooks should have
their `cache_session` / `cache_and_callback` steps dropped — the gateway already
populates its own cache — tracked separately rather than mutating the prod
catalog as part of a code-cleanup pass.
