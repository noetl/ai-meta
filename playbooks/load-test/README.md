# In-cluster load test rig

One command:

```bash
./playbooks/load-test/run-load-curve.sh                        # 1 2 4 6 8 10, 90s each
./playbooks/load-test/run-load-curve.sh --levels "2 6" --duration 120
./playbooks/load-test/run-load-curve.sh --repeat 2             # stability check
```

## Why it exists

Three harness artifacts corrupted earlier measurements, and each has a
countermeasure:

| artifact | what it produced | countermeasure |
| :-- | :-- | :-- |
| `kubectl port-forward` as the driver | a single TCP relay became the bottleneck; two runs measured the client and reported health while masking a real collapse | generators run **inside** the cluster as a Job |
| fixed `sleep` instead of waiting on the Job | pods that had not started yet yielded `0 ok / 0 err`, which reads as a stall | wait for **Job completion** |
| Autopilot's ~60–90 s node provisioning | scheduling counted as latency; short runs ended before pods started | window opens only once **all** generators are `Running`; `sched` reported separately |
| `grep -c error` over server logs | matched the word inside `EventEnvelope` payloads — **771 phantom errors** | generators emit `R\|ok\|<centis>`; parsed on `\|` only |

## Controls

- **Parser positive control** runs before any measurement and **aborts** if it
  fails. A zero from an unverified parser is not evidence — that is how the 771
  phantom errors and several false zeros happened.
- **Cross-check**: each row reconciles `submitted` (from the pods' own SUMMARY)
  against `ok + err` (from the `R|` lines) and flags a mismatch.
- **SKIP, not zero**: if fewer generators schedule than requested, the row says
  so with the count and elapsed time rather than reporting a misleading 0.

## Timing

`date +%s%3N` returns **whole seconds** in this image (busybox ignores `%3N`),
which is why an earlier rig captured no latency. `/proc/uptime` gives
centiseconds (verified: 101 over `sleep 1`) and is what the generator uses.

## Output

```
rep  conc  submit ok    err   p50ms    p95ms    rate/s    sched
1    2     27     27    0     640      17090    0.30      6s
```

`sched` is scheduling time, **excluded** from the measurement window.
