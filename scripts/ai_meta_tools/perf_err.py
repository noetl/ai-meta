import time
import re

def _is_missing_reference_error(message) -> bool:
    text = str(message or "").lower()
    if not text:
        return False

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

    return any(re.search(marker, text) for marker in ref_markers) and any(
        marker in text for marker in not_found_markers
    )

huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(1000)]}

t0 = time.time()
for _ in range(50):
    _is_missing_reference_error(huge_payload)
print(f"missing ref on huge dict: {time.time() - t0:.3f}s")
