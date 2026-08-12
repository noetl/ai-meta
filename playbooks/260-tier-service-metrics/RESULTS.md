# ai-meta#260 — gate results

Run 2026-08-11, kind cluster `kind-noetl`, on built images.
Worker branch `feat/260-tier-service-metrics` @ `dcd0266`, based on
`origin/main` (`dfcf9d9`, v5.115.3).

## Images

| tag | image id | source |
| :-- | :-- | :-- |
| `localhost/noetl-worker:260real` | `327e9d045e14` | committed tree @ `dcd0266` |
| `localhost/noetl-worker:260mut` | `6c405e9c7382` | same + `mutation.patch` |

**Provenance check.** The first build was launched in the background and its
`COPY . .` ran during a window when the mutation was briefly applied to the
working tree, so its contents were ambiguous. An independent rebuild from the
committed tree produced the **same image id** (`327e9d045e14`), which resolves
it — the layer hash is content-addressed, so an identical id means an identical
context. `260mut` has a different id, confirming the mutation reached the binary
rather than being silently ignored.

Both tags were verified present in the kind node **by name** before arming.

## Arm `off` — no listener ⇒ the series must not exist

`NOETL_EHDB_TIER_SERVICE_BIND` unset, `NOETL_EHDB_TIER_SERVICE_DIR` **still
set**, so an absence cannot be explained by "there was nothing to serve from".

```
=== arm off: 11 passed, 0 failed ===
  PASS  all 20 request series absent
  PASS  histogram {health,append,read_execution,scan,unsupported} absent
  PASS  store_{appends_total,bytes,sequence} absent
```

This is the discriminating arm. Without it the pinned zeros below prove nothing:
a renderer that emitted those lines unconditionally would produce an identical
`up` result. `/metrics` was 291 lines here vs 403 with the listener up — the
112-line delta is the tier-service surface appearing.

## Arm `up` — pinned at 0, then moving on the right labels

```
=== arm up: 41 passed, 0 failed ===
```

**Before any traffic** (the positive control the issue is about):

```
  PASS  all 20 request series exist before any traffic
  PASS  histogram health/append/read_execution/scan/unsupported exist (0)
  PASS  store_appends_total (0)  store_bytes (0)  store_sequence (0)
```

So a `0` reading means *no traffic*, not *metric absent*.

**Real operations over the real length-framed socket** (`tierctl.py`, not a
recorder call):

```
  health           -> ok tier-service v1
  append           -> {"appended":true,"global_sequence":1}
  append(empty id) -> invalid execution_id is empty
  read(hit)        -> exists:true, record_count 1, carries the GATE260 marker
  read(miss)       -> exists:false, record_count 0, no other execution's data
  scan             -> record_count 1
  unsupported      -> unsupported nonsense
  badframe         -> closed
```

**Counters, by label:**

| assertion | result |
| :-- | :-- |
| `health/ok +1` | ✅ |
| `append/ok +1` | ✅ |
| `append/invalid +1` | ✅ (reported, not asserted — see gate.sh) |
| `read_execution/hit +1` | ✅ |
| `read_execution/miss +1` | ✅ |
| `scan/hit +1` | ✅ |
| `unsupported/unsupported +1` | ✅ |
| `conn/protocol_error +1` | ✅ |
| `conn/accepted +8` (≥7 driven) | ✅ |

**Histogram** — counts move with the counter, `+Inf` equals `count`, and `sum`
is non-zero everywhere (a recorder firing with a hardcoded `0.0` would look
alive and measure nothing):

```
  health          count 1  sum 0.000008
  append          count 2  sum 0.002374
  read_execution  count 2  sum 0.000895
  scan            count 1  sum 0.000130
```

**Store**, observable without reading the tier:
`store_appends_total 1`, `store_bytes 379`, `store_sequence 1`.

## Mutation check — the gate must fail

`mutation.patch` drops the `record_tier_service` call for `append` only. The
append itself is untouched.

```
=== arm up: 38 passed, 2 failed ===        exit status 1

  FAIL  append/ok +1 — got '0', want '1'
  FAIL  append count +2 — got '0', want '2'
```

Exactly the two intended assertions failed, and nothing else regressed.

**The sharp part:** `store_appends_total +1` still **PASSED**, and the store
grew to `bytes 679, sequence 2`. The append really happened; only the
request-path signal disappeared. A weaker gate asserting "the store grew" would
have passed this mutation — which is precisely the invisibility #260 was filed
about, reproduced on demand.

## Kind restored

```
image:  ghcr.io/noetl/worker:5.115.3-arm64
NOETL_EHDB_TIER_SERVICE_* env vars: count=0
noetl-cmdbus-writer-0   1/1 Running
```

Worker working tree clean; `vendor/` (844 MB), `.cargo/config.toml` and
`Dockerfile.gate` removed — none is gitignored, so leaving them risked a future
`git add .` sweeping them in.

## Not done

* Nothing pushed. See `PENDING-PUSH.md`.
* No prod change; no tier flipped to `primary`; no tier-service env on prod.
* [ops#255](https://github.com/noetl/ops/pull/255) not applied — still the
  user's call. It needs no amendment: the metrics render on `:9090`, which the
  writer's Service already publishes.
