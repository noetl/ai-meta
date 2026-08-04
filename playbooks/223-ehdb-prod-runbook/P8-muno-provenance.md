# P8 — where the muno executions came from, and what "RUNNING" actually means on prod

**2026-08-04. Read-only investigation against `shastaratech-noetl-prod`.**

The question: *which namespace/pool submitted the muno executions, when, by what
trigger, and why has `muno/playbooks/itinerary-planner` been RUNNING since
2026-06-25?*

Answered from the prod event log directly, because the API cannot see far enough
to answer it (§1).

---

## 0. Headline

| Claim | Verdict |
| :-- | :-- |
| "70 stuck executions on prod" (P7) | **Wrong — the real number is 3359.** P7 read the API, which only reports non-terminal executions inside a bounded recent window. |
| "a real user-facing business execution, 40 days stalled" (P7) | **Wrong.** All 29 non-terminal muno runs are dev/QA. 20 were never executed on this cluster at all; the 2026-06-25 one is an explicitly-named smoke test. |
| "muno is test-only" | **Confirmed at the data level**, not just by assertion — every one is `user_uid=guest`, with hand-typed QA text. |

And one finding that has nothing to do with #227 but outranks it: §5.

---

## 1. Why the API under-counts, and the correct census

`GET /api/executions?status=RUNNING` does **not** return the RUNNING set. Per
`repos/server/src/services/execution.rs:236-249`, `limit` is clamped to 100 and a
status filter is applied *post-aggregation* within a candidate window of at most
`(limit+offset) × 10`, capped at 2000 — i.e. "the RUNNING ones among the ~1000
most-recent executions", a paginated-recent semantic. Anything older is
invisible.

That is a defensible API contract, but it means the P7 census (70) was an
artifact of the window, not a count.

The true census, computed over the whole log with the server's own terminal-state
rule (`playbook.completed|failed|cancelled`, or `status='FAILED'`):

```
non-terminal executions: 3359
```

By playbook (top rows):

| path | n | oldest | newest |
| :-- | --: | :-- | :-- |
| `automation/agents/mcp/firestore` | 2875 | 2026-05-12 | 2026-06-11 |
| `automation/agents/mcp/google-places` | 104 | 2026-05-12 | 2026-06-11 |
| `fixtures/playbooks/hello_world` | 66 | 2026-07-27 | 2026-08-01 |
| `automation/agents/mcp/duffel` | 44 | 2026-05-12 | 2026-05-16 |
| `team4/assistant/respond` | 42 | 2026-05-01 | 2026-05-04 |
| **`muno/playbooks/itinerary-planner`** | **29** | 2026-05-13 | 2026-06-25 |
| `system/scheduled_cleanup` | 12 | 2026-06-21 | 2026-08-01 |

The bulk is not muno — it is the MCP agent child-playbooks muno fans out to
(`firestore`, `google-places`, `duffel`, `amadeus`), at roughly 100 children per
parent turn.

---

## 2. Provenance: 1699 of the 3359 were never executed on this cluster

`noetl.event.ingest_time` defaults to `now()`, which in Postgres is
**transaction-start** time. So a group of rows sharing one `ingest_time` to the
microsecond is one transaction.

```
ingest_time                     rows
2026-05-18 04:31:47.130085+00   570623      <-- one transaction
2026-05-18 04:43:30.940053+00        8
...
```

**570,623 events entered this database in a single transaction on 2026-05-18
04:31:47**, with `created_at` spanning 2026-02-26 → 2026-05-16. That is the
`noetl-demo-19700101` → `shastaratech-noetl-prod` migration bulk-loading the old
prod event log.

Of the 3359 non-terminal executions, **1699 carry that ingest stamp.** They were
already non-terminal in the *source* cluster when the log was copied, and
importing an event log cannot resurrect an in-flight execution: there is no
command, no worker, no bus entry — only history. They are non-convergent **by
construction** and no amount of runtime repair will ever move them.

This is the single most important fact for Part B: the largest cohort of "stuck"
executions is not stuck, it is *imported*.

---

## 3. The 29 muno runs, individually

| origin | n | window |
| :-- | --: | :-- |
| **MIGRATED-IN** (ingest 2026-05-18 04:31:47, created 2026-05-13→15) | **20** | never ran here |
| native to this cluster | 9 | 2026-05-21 → 2026-06-25 |

The 9 natives, by submitting trigger — read from the start event's workload:

| execution_id | started | thread_id | user | text |
| :-- | :-- | :-- | :-- | :-- |
| 631953496383685087 | 2026-05-21 22:18 | `chat-mpg1xr4n-6ekmp5` | guest | *(empty)* |
| 632110245082301156 | 2026-05-22 03:30 | `chat-mpgd30xh-orrwql` | guest | `trip to Lndon` |
| 632172447885689837 | 2026-05-22 05:33 | `chat-mpggzqxs-cw9e9p` | guest | `trip to Las Vegas` |
| 632196592136618031 | 2026-05-22 06:21 | `chat-mpgj7n0l-op7usn` | guest | `trip to Paris` |
| 633479183926035187 | 2026-05-24 00:50 | `chat-mpj28sh5-lcyu39` | guest | `trip to paris` |
| 636532213848211757 | 2026-05-28 05:55 | `chat-mpp2suit-gpktq9` | guest | *(empty)* |
| 641524675050209625 | 2026-06-04 03:15 | `chat-mpyx4g8g-8yncqm` | guest | `what hitel I need to stay in paris` |
| 643028416526025291 | 2026-06-06 05:02 | `chat-mq1vutue-m3i74q` | guest | *(empty)* |
| **328414768463355904** | **2026-06-25 06:03** | **`_smoke-rust-fix-20260625`** | guest | `trip to Paris` |

**Trigger**: `thread-id = chat-<nanoid>` is the Muno SPA's chat-session id. These
arrived through the `gateway` namespace (`Deployment/gateway`, LoadBalancer
`34.132.30.16`) → `POST /api/execute` on `noetl-server-rust` in namespace
`noetl`, and were executed by the **user pool** (`noetl-worker-rust-*`; the
older `worker-<hex>` ids in the migrated set are pre-migration Python workers).

**Every one is `user_uid=guest`.** None is an authenticated customer. The typos
(`Lndon`, `hitel`, lowercase `paris`) are a person typing into the dev SPA. The
2026-06-25 one does not even pretend — its thread id is literally
`_smoke-rust-fix-20260625`, a smoke test named after the Rust-server fix work
that day.

**muno is test-only, confirmed from the data.** P7's "a real user-facing business
execution" was an over-read of the path name.

### 3.1 Why the 2026-06-25 one has been RUNNING for 40 days

It has not been *running* for 40 days. It ran for **18 seconds** and then stopped
emitting:

```
06:03:02.474 playbook_started   muno/playbooks/itinerary-planner
06:03:03.375 command.completed  start
06:03:05.212 command.completed  normalize_input
06:03:07.018 command.completed  load_slot_state
06:03:16.698 command.completed  extract_turn
06:03:17.949 command.completed  persist_turn_docs_atomically
06:03:19.522 command.completed  append_turn_events_atomically
06:03:20.508 step.skipped       call_google_places
06:03:20.509 step.skipped       call_duffel_offers
06:03:20.512 step.skipped       call_amadeus_hotels
06:03:20.513 step.skipped       call_duffel_create_order
06:03:20.515 step.skipped       render_widget_chat
                        <-- nothing, ever again
```

Every step succeeded. Then all five conditional branches evaluated false, the
orchestrator issued **no successor command**, and emitted **no terminal event**.

So there is nothing wedged: no outstanding command, no worker holding a slot, no
retry loop. The execution is *finished* and merely never *finalized*. It is
`RUNNING` only because "RUNNING" is defined as the absence of a terminal event.

This matters enormously for Part B, because it is **not** the #227 shape and
**not** the #171 shape.

---

## 4. Four distinct stall shapes, not one

Sampling the non-terminal set turns up at least four unrelated causes:

| # | shape | last event | example | what it is |
| :-- | :-- | :-- | :-- | :-- |
| A | **all branches skipped, no successor** | `step.skipped` | 328414768463355904 | DAG ran to completion; orchestrator never emitted a terminal |
| B | **command issued, never claimed** | `command.issued … PENDING` | 636532213848211757, 643028416526025291 | genuine orphan — but no `command.claimed`, so **#171 cannot see it** |
| C | **already cancelled, projected RUNNING** | `execution.cancelled` | 632110245082301156, 632172447885689837, 632196592136618031 | not stuck at all — a status-projection bug (§4.1) |
| D | **imported history** | `batch.completed` | the 20 migrated | never ran here |

### 4.1 Shape C is a real bug worth fixing on its own

`repos/server/src/services/execution.rs:301` treats only
`playbook.cancelled` / `playbook_cancelled` as the cancelled terminal. The event
these executions actually carry is **`execution.cancelled`**, which is in neither
the terminal list nor the `status='FAILED'` clause — so an execution that was
explicitly cancelled through the API still reports `RUNNING` forever.

Three of the nine native muno runs are in this state. They need no sweep; they
need the projection to recognise the event that is already there.

### 4.2 Why #171 has not cleaned any of this up

`NOETL_ORPHAN_SWEEP_ENABLED=true` **is** set on prod (`Deployment/noetl-server-rust`),
and the sweep is working as designed. It cannot reach any of these because:

1. **`orphan_sweep_lookback_secs` defaults to 48h**
   (`repos/server/src/config/app.rs:771`). Everything above is 40–160 days old
   and therefore outside the candidate scan by construction.
2. **Its predicate requires a `command.claimed`** whose owner worker is dead
   (`repos/server/src/handlers/orphan_sweep.rs:265-311`). Shapes A, C and D have
   no outstanding claim at all, and shape B never got claimed. Only a claimed-
   then-abandoned command matches.

Both are correct choices for the zombie #171 was built for. They just mean #171
is structurally the wrong instrument for this backlog — which is precisely why
Part B needs its own predicate rather than a relaxation of #171's.

---

## 5. ⚠ Unrelated finding, higher priority than #227: live third-party API keys are sitting in the permanent event log

While reading the migrated muno workloads:

```
noetl.event.context → result → workload → keychain →
    openai_token.api_key     = "sk-svcacct-…"     (full key, plaintext)
    anthropic_token.api_key  = "sk-ant-api03-…"   (full key, plaintext)
```

Scope, measured:

| | |
| :-- | --: |
| events carrying a plaintext `keychain … api_key` | **6247** |
| distinct executions | **2665** |
| first seen | **2026-02-26** |
| last seen | **2026-05-29** |

Top paths: `automation/agents/mcp/firestore` (4237), `muno/playbooks/itinerary-planner`
(965), `automation/agents/mcp/google-places` (174), `api_integration/amadeus_ai_api`
(172), `automation/agents/travel/runtime` (165).

**Facts that matter:**

- The **leak has stopped** — nothing after 2026-05-29. Muno moved from inline
  `keychain.{openai,anthropic}_token` to GSM references (`openai_secret_path` /
  `anthropic_secret_path`), which is what the 2026-06-25 workload shows. This is
  the same class of defect as the #151 drive-leak fix, on a different path.
- The **exposure has not stopped.** `noetl.event` is append-only and never
  purged (standing constraint). These rows cannot be deleted, and they migrated
  into the new cluster with everything else — the keys now exist in two projects'
  backups.
- Response-boundary scrubbing (`scrub::scrub_in_place`) masks these on the API,
  but **any operator with a Postgres read** sees them in full, as I just did.

**The only real remediation is rotating both keys**, which is a credential
operation I will not perform. Flagged for the user; tracking issue opened with no
key material in it (public repo).

---

## 6. What this changes for Part B

1. The target set is **3359**, not 70 — but ~1699 of those are imported history
   that no runtime predicate should even look at. Any sweep must be able to tell
   "imported" from "stalled", or it will spend its budget on rows that were never
   alive here.
2. There are **four shapes, not one**. A single "non-convergence" predicate that
   assumes the #227 rehydrate-exhausted shape would terminate approximately none
   of this backlog.
3. **Shape C is not a sweep problem at all** and should be fixed in the status
   projection before any sweep runs — otherwise the sweep will emit
   `playbook.failed` over executions that were already deliberately cancelled,
   turning a clean CANCELLED into a misleading FAILED.
4. Blast radius is **lower** than P7 feared (nothing here is customer work), but
   **wider** (48× more rows), so the per-tick cap and the ordering matter more
   than the eligibility rule does.
