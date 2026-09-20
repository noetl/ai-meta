#!/usr/bin/env python3
"""M5 fencing mutation battery — same three assertions per arm as M0.5."""
import re,subprocess,sys,pathlib
ROOT=pathlib.Path(sys.argv[1])
M=[
 ("F1","the pre-append precheck is removed (the publish-skip gap returns)",
  "src/ehdb/eventlog_backend.rs",
  "            if let Some(detail) = stale_epoch_precheck(env, contract, shard) {\n                return Ok(AppendDispatch::FencedStale { detail });\n            }\n",
  "",
  "ehdb::eventlog_backend::tests::a_stale_writer_whose_segment_is_no_longer_than_the_holders_is_still_fenced"),
 ("F2","the precheck refuses under SHADOW too (shadow must not change behaviour)",
  "src/ehdb/eventlog_backend.rs",
  "    if setting != FencingSetting::Enforce {\n        // \u26a0\u26a0 SHADOW COUNTS",
  "    if setting == FencingSetting::Off {\n        // \u26a0\u26a0 SHADOW COUNTS",
  "ehdb::eventlog_backend::tests::the_same_stale_write_SUCCEEDS_under_shadow"),
 ("F3","the precheck refuses a writer that is NOT behind (refuses everyone)",
  "src/ehdb/eventlog_backend.rs",
  "    if epoch >= highest {\n        return None;\n    }", "    if epoch > highest {\n        return None;\n    }",
  "ehdb::eventlog_backend::tests::a_writer_at_the_current_epoch_is_served_under_enforce"),
 # F4 was "delete the decorator's is_stale_epoch arm". It SURVIVED, correctly:
 # the precheck refuses first, so that arm now only covers the race window
 # (marker advances between the precheck's read and the publish) and no unit
 # test here can force that interleaving. Recorded in a comment at the arm
 # rather than replaced by a test that only appears to cover it.
 ("F4","the precheck opens the ledger under the LOCAL root, not the shared one",
  "src/ehdb/eventlog_backend.rs",
  "    let ledger = ehdb_fencing::FencingLedger::new(paths.shared_root.join(\".fencing\")).ok()?;",
  "    let ledger = ehdb_fencing::FencingLedger::new(paths.local_root.join(\".fencing\")).ok()?;",
  "ehdb::eventlog_backend::tests::a_stale_writer_whose_segment_is_no_longer_than_the_holders_is_still_fenced"),
 ("F5","the refusal text is hand-written instead of the crate's constructor",
  "src/ehdb/eventlog_backend.rs",
  "    Some(ehdb_fencing::stale_epoch_error(shard, epoch, highest).to_string())",
  '    Some(format!("write refused: epoch {epoch} behind {highest} on shard {shard}"))',
  "ehdb::eventlog_backend::tests::a_stale_writer_whose_segment_is_no_longer_than_the_holders_is_still_fenced"),
 ("F6","the precheck refuses but never counts it (stale_refused reads 0 while fencing)",
  "src/ehdb/eventlog_backend.rs",
  "    FENCING_METRICS\n        .stale_refused\n        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);\n",
  "",
  "ehdb::eventlog_backend::tests::a_stale_writer_whose_segment_is_no_longer_than_the_holders_is_still_fenced"),
 ("F7","shadow stops counting the observation (a shadow period that reports 0 by construction)",
  "src/ehdb/eventlog_backend.rs",
  "    PRECHECK_STALE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);\n    if setting != FencingSetting::Enforce {",
  "    if setting != FencingSetting::Enforce {",
  "ehdb::eventlog_backend::tests::the_same_stale_write_SUCCEEDS_under_shadow"),
 ("F8","the precheck sums into the DECORATOR's counter again (double-counts shadow)",
  "src/ehdb/eventlog_backend.rs",
  "    PRECHECK_STALE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);",
  "    PRECHECK_STALE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);\n    FENCING_METRICS.stale_observed.fetch_add(1, std::sync::atomic::Ordering::Relaxed);",
  "ehdb::eventlog_backend::tests::the_same_stale_write_SUCCEEDS_under_shadow"),
]
def run(f):
    p=subprocess.run(["cargo","test","--lib",f,"--","--exact"],cwd=ROOT,capture_output=True,text=True)
    o=p.stdout+p.stderr
    if re.search(r"^error(\[|:)",o,re.M) and "test failed" not in o: return "COMPILE_ERROR",0,o
    m=re.search(r"running (\d+) tests?",o); n=int(m.group(1)) if m else 0
    if "test result: ok." in o and n>0: return "PASS",n,o
    if "test result: FAILED" in o: return "FAIL",n,o
    return "UNKNOWN",n,o
rows=[];bad=0
for _i,_d,_f,_o,_n,filt in M:
    v,n,o=run(filt); ok=(v=="PASS" and n==1)
    if not ok: bad+=1; print(o[-1500:])
    rows.append(("BASELINE",filt.rsplit("::",1)[-1][:58],f"{v} n={n}","ok" if ok else "⚠ NOT GREEN"))
if bad:
    print("⛔ baseline not green"); [print(r) for r in rows]; sys.exit(1)
for mid,desc,rel,old,new,filt in M:
    p=ROOT/rel; src=p.read_text()
    if old not in src: rows.append((mid,desc,"ANCHOR NOT FOUND","⚠ NEVER APPLIED")); bad+=1; continue
    p.write_text(src.replace(old,new,1))
    try: v,n,o=run(filt)
    finally: p.write_text(src)
    if n==0 and v!="COMPILE_ERROR": rows.append((mid,desc,f"{v} n=0","⚠ TEST DID NOT RUN")); bad+=1
    elif v=="FAIL": rows.append((mid,desc,f"FAIL n={n}","CAUGHT"))
    else:
        rows.append((mid,desc,f"{v} n={n}","⚠ SURVIVED")); bad+=1; print(f"--- {mid}\n{o[-1200:]}")
print()
for r in rows: print(" | ".join(str(x) for x in r))
print(f"\n{'ALL GREEN' if bad==0 else f'{bad} PROBLEM ARM(S)'}")
sys.exit(1 if bad else 0)
