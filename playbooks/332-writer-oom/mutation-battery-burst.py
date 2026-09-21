#!/usr/bin/env python3
"""Mutation battery for the reconnect-burst bound. Same three assertions per arm."""
import re,subprocess,sys,pathlib
ROOT=pathlib.Path(sys.argv[1])
M=[
 ("B1","the bound is removed entirely (back to unbounded spawn-per-accept)",
  "src/ehdb/tier_service.rs",
  "        let permit = match std::sync::Arc::clone(&permits).acquire_owned().await {",
  "        #[allow(unused)] let permit = match std::sync::Arc::clone(&permits).try_acquire_owned() {",
  "ehdb::tier_service::reconnect_burst_tests::the_real_accept_loop_takes_its_permit_before_accepting"),
 ("B2","an unusable cap widens the bound instead of failing safe",
  "src/ehdb/tier_service.rs",
  "    raw.and_then(|v| v.trim().parse::<usize>().ok())\n        .filter(|n| *n > 0)\n        .unwrap_or(TIER_MAX_INFLIGHT_DEFAULT)",
  "    raw.and_then(|v| v.trim().parse::<usize>().ok())\n        .unwrap_or(TIER_MAX_INFLIGHT_DEFAULT)",
  "ehdb::tier_service::reconnect_burst_tests::an_unusable_cap_falls_back_to_the_default_rather_than_unbounded"),
 ("B3","the default cap becomes 0 (a bound that wedges the service)",
  "src/ehdb/tier_service.rs",
  "pub const TIER_MAX_INFLIGHT_DEFAULT: usize = 4;",
  "pub const TIER_MAX_INFLIGHT_DEFAULT: usize = 0;",
  "ehdb::tier_service::reconnect_burst_tests::an_unusable_cap_falls_back_to_the_default_rather_than_unbounded"),
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
    if not ok: bad+=1; print(o[-1200:])
    rows.append(("BASELINE",filt.rsplit("::",1)[-1][:52],f"{v} n={n}","ok" if ok else "⚠ NOT GREEN"))
if bad:
    print("⛔ baseline not green"); [print(r) for r in rows]; sys.exit(1)
for mid,desc,rel,old,new,filt in M:
    p=ROOT/rel; src=p.read_text()
    if old not in src: rows.append((mid,desc,"ANCHOR NOT FOUND","⚠ NEVER APPLIED")); bad+=1; continue
    p.write_text(src.replace(old,new,1))
    try: v,n,o=run(filt)
    finally: p.write_text(src)
    if n==0 and v!="COMPILE_ERROR": rows.append((mid,desc,f"{v} n=0","⚠ DID NOT RUN")); bad+=1
    elif v in ("FAIL","COMPILE_ERROR"): rows.append((mid,desc,f"{v} n={n}","CAUGHT"))
    else: rows.append((mid,desc,f"{v} n={n}","⚠ SURVIVED")); bad+=1; print(f"--- {mid}\n{o[-900:]}")
print()
for r in rows: print(" | ".join(str(x) for x in r))
print(f"\n{'ALL GREEN' if bad==0 else f'{bad} PROBLEM ARM(S)'}")
sys.exit(1 if bad else 0)
