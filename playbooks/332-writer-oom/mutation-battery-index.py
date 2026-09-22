#!/usr/bin/env python3
import re,subprocess,sys,pathlib
ROOT=pathlib.Path(sys.argv[1]); F="src/ehdb/tier_store.rs"
EQ="ehdb::tier_store::tests::an_indexed_read_returns_exactly_what_an_unindexed_read_returns"
SKIP="ehdb::tier_store::tests::the_index_actually_rules_segments_out"
MISS="ehdb::tier_store::tests::a_segment_without_an_index_is_always_opened"
M=[
 ("I1","a MISSING index is treated as 'does not contain' (silent skip of real records)",F,
  "            None => true,","            None => false,",MISS),
 ("I2","the index is never consulted (every read opens every segment)",F,
  "            Some(ids) => ids.contains(execution_id),","            Some(_) => true,",SKIP),
 ("I3","the index inverts its membership test (skips exactly the segments it should open)",F,
  "            Some(ids) => ids.contains(execution_id),","            Some(ids) => !ids.contains(execution_id),",EQ),
 ("I4","the index build drops ids beyond the first page",F,
  "        if out.records.len() < MAX_SCAN_LIMIT {\n            break;\n        }","        break;","ehdb::tier_store::tests::the_index_build_pages_past_the_scan_limit"),
 ("I5","the index is written WITHOUT the atomic rename (a partial index reads as complete)",F,
  "    std::fs::write(&tmp, body.as_bytes()).map_err(|e| e.to_string())?;\n    std::fs::rename(&tmp, &final_path).map_err(|e| e.to_string())?;",
  "    std::fs::write(&final_path, body.as_bytes()).map_err(|e| e.to_string())?;",None),
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
    if filt is None: continue
    v,n,o=run(filt); ok=(v=="PASS" and n==1)
    if not ok: bad+=1; print(o[-1000:])
    rows.append(("BASELINE",filt.rsplit("::",1)[-1][:46],f"{v} n={n}","ok" if ok else "⚠ NOT GREEN"))
if bad: print("⛔ baseline not green"); [print(r) for r in rows]; sys.exit(1)
for mid,desc,rel,old,new,filt in M:
    if filt is None:
        rows.append((mid,desc,"NO TEST","⚠ UNCOVERED — stated, not hidden")); continue
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
