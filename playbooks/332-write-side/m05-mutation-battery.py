#!/usr/bin/env python3
"""M0.5 E2/E5 mutation battery.

Every arm asserts THREE things, because each has produced a false SURVIVED in
this program:
  1. the mutation text was actually found and applied (anchor drift),
  2. the test actually ran (`running N tests`, N > 0 — a typo'd module path
     reports "0 passed; 0 failed" and reads as green),
  3. the verdict matches the expectation.
Plus a BASELINE arm on the unmutated tree: a red baseline makes every mutant
read CAUGHT.
"""
import re, subprocess, sys, pathlib

ROOT = pathlib.Path(sys.argv[1])

MUTATIONS = [
    # (id, spec-defect, file, old, new, test filter, what must go red)
    ("M1", "#1 dispatch ignores the flag, always local_reference",
     "src/ehdb/tier_store.rs",
     "    match backend {\n        TierBackend::LocalReference => Box::new(LocalReferenceEventLogDriver::new(",
     "    match TierBackend::LocalReference {\n        TierBackend::LocalReference => Box::new(LocalReferenceEventLogDriver::new(",
     "ehdb::tier_store::tests::the_l0_backend_round_trips_append_read_and_scan"),

    ("M2", "#2 dispatch ignores the flag, always l0",
     "src/ehdb/tier_store.rs",
     "    match backend {\n        TierBackend::LocalReference => Box::new(LocalReferenceEventLogDriver::new(",
     "    match TierBackend::L0 {\n        TierBackend::LocalReference => Box::new(LocalReferenceEventLogDriver::new(",
     "ehdb::tier_store::tests::the_dispatch_under_local_reference_is_byte_identical_to_the_incumbent"),

    ("M3", "#3 cross-backend read returns Ok with the other engine's records",
     "src/ehdb/tier_store.rs",
     "            match super::l0_tier_driver::L0TierDriver::open(&root) {",
     "            if true { return Box::new(LocalReferenceEventLogDriver::new(\n                cfg.path_for(tier),\n                DEFAULT_LOCAL_REFERENCE_TENANT.to_string(),\n                DEFAULT_LOCAL_REFERENCE_NAMESPACE.to_string(),\n            )); }\n            match super::l0_tier_driver::L0TierDriver::open(&root) {",
     "ehdb::tier_store::tests::a_store_written_by_one_backend_is_refused_by_the_other"),

    ("M4", "#4 an unrecognised flag value falls through to l0",
     "src/ehdb/tier_store.rs",
     '            Some("l0") => Self::L0,\n            _ => Self::LocalReference,',
     '            Some("l0") => Self::L0,\n            _ => Self::L0,',
     "ehdb::tier_store::tests::unrecognised_backend_values_are_local_reference"),

    ("M5", "E5 the gauge pins only the SELECTED backend (absent != zero)",
     "src/ehdb/metrics.rs",
     "    for known in TIER_BACKENDS {\n        s.tier_backend.insert(known, 0);\n    }\n",
     "",
     "ehdb::metrics::tests::the_backend_gauge_pins_every_label_value_under_either_backend"),

    ("M6", "E5 the recorder exists but the dispatch never calls it",
     "src/ehdb/tier_store.rs",
     "    super::metrics::record_tier_backend(backend.as_str());",
     "    let _ = backend.as_str();",
     "ehdb::tier_store::tests::the_dispatch_records_which_backend_it_selected"),

    ("M7", "E5 the pin moves INSIDE a config branch (the server#315 shape)",
     "src/ehdb/metrics.rs",
     "    if s.tier_backend_up {",
     "    if s.tier_backend_up && s.tier_service_up {",
     "ehdb::tier_store::tests::the_dispatch_records_which_backend_it_selected"),
]

def run(filt):
    p = subprocess.run(["cargo", "test", "--lib", filt, "--", "--exact"],
                       cwd=ROOT, capture_output=True, text=True)
    out = p.stdout + p.stderr
    if re.search(r"^error(\[|:)", out, re.M) and "test failed" not in out:
        return "COMPILE_ERROR", 0, out
    m = re.search(r"running (\d+) tests?", out)
    n = int(m.group(1)) if m else 0
    if "test result: ok." in out and n > 0:
        return "PASS", n, out
    if "test result: FAILED" in out:
        return "FAIL", n, out
    return "UNKNOWN", n, out

rows, bad = [], 0

# ---- BASELINE -------------------------------------------------------------
for _id, _d, _f, _o, _n, filt in MUTATIONS:
    v, n, out = run(filt)
    ok = (v == "PASS" and n == 1)
    if not ok:
        bad += 1
        print(out[-2500:])
    rows.append(("BASELINE", filt.rsplit("::", 1)[-1], f"{v} n={n}", "ok" if ok else "⚠ BASELINE NOT GREEN"))

if bad:
    print("\n⛔ baseline is not green — every mutant below would read CAUGHT. Stopping.")
    for r in rows: print(r)
    sys.exit(1)

# ---- MUTANTS --------------------------------------------------------------
for mid, desc, rel, old, new, filt in MUTATIONS:
    p = ROOT / rel
    src = p.read_text()
    if old not in src:
        rows.append((mid, desc, "ANCHOR NOT FOUND", "⚠ MUTATION NEVER APPLIED"))
        bad += 1
        continue
    mutated = src.replace(old, new, 1)
    assert mutated != src
    p.write_text(mutated)
    try:
        v, n, out = run(filt)
    finally:
        p.write_text(src)
    if n == 0 and v != "COMPILE_ERROR":
        rows.append((mid, desc, f"{v} n=0", "⚠ TEST DID NOT RUN"))
        bad += 1
    elif v == "FAIL":
        rows.append((mid, desc, f"FAIL n={n}", "CAUGHT"))
    else:
        rows.append((mid, desc, f"{v} n={n}", "⚠ SURVIVED"))
        bad += 1
        print(f"--- {mid} output tail ---\n{out[-1500:]}")

print()
for r in rows:
    print(" | ".join(str(x) for x in r))
print(f"\n{'ALL GREEN' if bad == 0 else f'{bad} PROBLEM ARM(S)'}")
sys.exit(1 if bad else 0)
