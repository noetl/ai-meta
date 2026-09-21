#!/usr/bin/env python3
import re,subprocess,sys,pathlib
ROOT=pathlib.Path(sys.argv[1])
T="ehdb::tier_store::tests::sealing_bounds_the_active_segment_and_loses_no_records"
F="src/ehdb/tier_store.rs"
M=[
 ("S1","reads ignore sealed segments (the data-loss failure)", F,
  "    let sealed = sealed_segments(cfg, tier);\n    if !sealed.is_empty() {\n        return read_execution_across_segments(cfg, tier, execution_id, &sealed, &request);\n    }\n","",T),
 ("S2","SCAN ignores sealed segments (the gap the env leak exposed)", F,
  "    let sealed = sealed_segments(cfg, tier);\n    if !sealed.is_empty() {\n        return scan_across_segments(cfg, tier, &sealed, after, limit);\n    }\n","",T),
 ("S3","sealing never fires (the store stays unbounded)", F,
  "    let _ = maybe_seal(cfg, tier, seal_max);","    let _ = seal_max;",T),
 ("S4","a stray non-numeric suffix is replayed as tier data", F,
  "            if let Ok(n) = rest.parse::<u64>() {\n                found.push((n, p));\n            }",
  "            found.push((rest.parse::<u64>().unwrap_or(0), p));",
  "ehdb::tier_store::tests::only_numbered_suffixes_count_as_segments"),
 ("S5","the seal threshold stops failing safe to OFF", F,
  "    raw.and_then(|v| v.trim().parse::<u64>().ok()).filter(|n| *n > 0)",
  "    raw.and_then(|v| v.trim().parse::<u64>().ok()).or(Some(1))",
  "ehdb::tier_store::tests::the_seal_is_off_unless_explicitly_configured"),
 ("S6","a merged read renumbers wrongly (duplicate sequences leak out)", F,
  "    for (i, r) in records.iter_mut().enumerate() {\n        if let Some(o) = r.as_object_mut() {\n            o.insert(\n                \"global_sequence\".to_string(),\n                serde_json::Value::from((i + 1) as u64),\n            );\n        }\n    }\n    let n = records.len();","    let n = records.len();",T),
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
    rows.append(("BASELINE",filt.rsplit("::",1)[-1][:50],f"{v} n={n}","ok" if ok else "⚠ NOT GREEN"))
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
    else: rows.append((mid,desc,f"{v} n={n}","⚠ SURVIVED")); bad+=1
print()
for r in rows: print(" | ".join(str(x) for x in r))
print(f"\n{'ALL GREEN' if bad==0 else f'{bad} PROBLEM ARM(S)'}")
sys.exit(1 if bad else 0)
