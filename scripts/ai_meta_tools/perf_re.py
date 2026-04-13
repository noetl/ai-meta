import time
import re
text = "ReferenceError: missing reference noetl://execution/123/result"

t0 = time.time()
for _ in range(50000):
    ref_markers = (
        r"\bresult_ref\b",
        r"\b_ref\b",
        r"\breference\b",
        r"\bdata_reference\b",
        r"noetl://",
        r"\bartifact\b",
    )
    not_found_markers = (
        "not found",
        "missing",
        "no message found",
        "keyerror",
        "filenotfounderror",
        "does not exist",
    )

    t = text.lower()
    any(re.search(marker, t) for marker in ref_markers) and any(
        marker in t for marker in not_found_markers
    )

print(f"regex missing reference overhead: {time.time() - t0:.3f}s")
