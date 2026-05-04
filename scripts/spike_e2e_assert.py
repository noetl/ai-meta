"""Validate the diagnosis envelope returned by the NoETL-as-AI-OS e2e smoke.

Reads JSON from a file path or stdin, asserts the spike_e2e_test
playbook's result has the expected shape:

- top-level `smoke_status: ok`
- `agent_envelope` shows the sub-playbook failed (status=error)
- `agent_envelope.error.diagnosis` is attached (Gap 4.1 contract)
- diagnosis has all the documented fields with valid types

Usage::

    # From a saved JSON dump:
    python3 scripts/spike_e2e_assert.py /tmp/exec-result.json

    # Piped from `noetl execution result`:
    noetl execution result <exec-id> --json | python3 scripts/spike_e2e_assert.py -

Exits 0 on pass, 1 on fail. Prints a concise per-check summary so
CI logs stay readable.
"""

from __future__ import annotations

import json
import sys
from typing import Any


# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------


def _check(label: str, condition: bool, detail: str = "") -> bool:
    """Print PASS/FAIL line; return condition for accumulation."""
    marker = "PASS" if condition else "FAIL"
    suffix = f" — {detail}" if detail else ""
    print(f"[{marker}] {label}{suffix}")
    return condition


def assert_envelope(result: dict) -> int:
    """Walk the spike_e2e_test result, return 0 on pass / 1 on fail."""
    passed_all = True

    # ------------------------------------------------------------------
    # Top-level smoke shape
    # ------------------------------------------------------------------
    passed_all &= _check(
        "result is a dict",
        isinstance(result, dict),
        f"got {type(result).__name__}",
    )
    if not isinstance(result, dict):
        return 1

    passed_all &= _check(
        "smoke_status == 'ok'",
        result.get("smoke_status") == "ok",
        f"got {result.get('smoke_status')!r}",
    )

    # ------------------------------------------------------------------
    # Agent envelope (failed sub-playbook)
    # ------------------------------------------------------------------
    envelope = result.get("agent_envelope")
    passed_all &= _check(
        "agent_envelope is a dict",
        isinstance(envelope, dict),
        f"got {type(envelope).__name__ if envelope is not None else 'None'}",
    )
    if not isinstance(envelope, dict):
        return 1

    passed_all &= _check(
        "agent_envelope.status == 'error' (sub-playbook should have failed)",
        envelope.get("status") == "error",
        f"got {envelope.get('status')!r}",
    )
    passed_all &= _check(
        "agent_envelope.framework == 'noetl' (Gap 1)",
        envelope.get("framework") == "noetl",
        f"got {envelope.get('framework')!r}",
    )

    error_block = envelope.get("error")
    passed_all &= _check(
        "agent_envelope.error is a dict",
        isinstance(error_block, dict),
        f"got {type(error_block).__name__ if error_block is not None else 'None'}",
    )
    if not isinstance(error_block, dict):
        return 1

    passed_all &= _check(
        "agent_envelope.error.kind == 'agent.execution'",
        error_block.get("kind") == "agent.execution",
        f"got {error_block.get('kind')!r}",
    )

    # ------------------------------------------------------------------
    # Gap 4.1: diagnosis attached to the error envelope
    # ------------------------------------------------------------------
    diagnosis = error_block.get("diagnosis") or result.get("diagnosis")
    passed_all &= _check(
        "diagnosis attached (Gap 4.1 auto-dispatch)",
        isinstance(diagnosis, dict),
        f"got {type(diagnosis).__name__ if diagnosis is not None else 'None'}",
    )
    if not isinstance(diagnosis, dict):
        return 1

    # ------------------------------------------------------------------
    # Diagnosis envelope shape (per Gap 4 contract)
    # ------------------------------------------------------------------
    required_keys = ("category", "confidence", "root_cause", "suggested_action", "source")
    for key in required_keys:
        passed_all &= _check(
            f"diagnosis.{key} present",
            key in diagnosis,
            f"keys: {sorted(diagnosis.keys())}",
        )

    # Type / range checks
    confidence = diagnosis.get("confidence")
    passed_all &= _check(
        "diagnosis.confidence is numeric in [0.0, 1.0]",
        isinstance(confidence, (int, float)) and 0.0 <= float(confidence) <= 1.0,
        f"got {confidence!r}",
    )

    category = diagnosis.get("category", "")
    valid_categories = (
        "transient_5xx", "auth", "rate_limit", "bad_request",
        "tool_error", "infra", "unknown",
    )
    passed_all &= _check(
        "diagnosis.category is from documented set",
        isinstance(category, str) and category in valid_categories,
        f"got {category!r}; valid: {valid_categories}",
    )

    source = diagnosis.get("source", "")
    valid_sources = ("ollama", "openai", "claude", "remote")
    passed_all &= _check(
        "diagnosis.source is from documented set",
        isinstance(source, str) and source in valid_sources,
        f"got {source!r}; valid: {valid_sources}",
    )

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    print()
    if passed_all:
        print("=" * 60)
        print("All checks passed. NoETL-as-AI-OS spike e2e smoke is GREEN.")
        print(f"  Diagnosis source:      {diagnosis.get('source')}")
        print(f"  Diagnosis category:    {diagnosis.get('category')}")
        print(f"  Diagnosis confidence:  {diagnosis.get('confidence')}")
        print(f"  Root cause:            {diagnosis.get('root_cause', '')[:80]}")
        print("=" * 60)
        return 0
    else:
        print("=" * 60)
        print("One or more checks FAILED. See [FAIL] lines above.")
        print("=" * 60)
        return 1


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def _load_input(arg: str) -> Any:
    """Load JSON from a file path or stdin (when arg == '-')."""
    if arg == "-":
        return json.load(sys.stdin)
    with open(arg) as f:
        return json.load(f)


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        return 2

    raw = _load_input(sys.argv[1])

    # Accept either:
    #   1. The bare extract_envelope result (smoke_status, agent_envelope, ...)
    #   2. A noetl execution-result envelope that wraps it under
    #      data / result / output (different CLI subcommands wrap
    #      the result differently; tolerate all shapes).
    candidates = [raw]
    if isinstance(raw, dict):
        for key in ("data", "result", "output"):
            if isinstance(raw.get(key), dict):
                candidates.append(raw[key])

    # Pick the first candidate that looks like our smoke output
    target = None
    for c in candidates:
        if isinstance(c, dict) and "smoke_status" in c:
            target = c
            break

    if target is None:
        # Fall through to the raw input — assertion will print useful
        # messages about what's missing.
        target = raw

    return assert_envelope(target)


if __name__ == "__main__":
    sys.exit(main())
