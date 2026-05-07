#!/usr/bin/env python3
"""Detect event-projection regressions between live and persisted results.

Static mode validates canned fixtures:
  * a v2.35.9-shaped event pair that must pass
  * a v2.35.8 regression-shaped pair that must fail with
    NESTED_DICT_LOSS at result.context.error.diagnosis
  * a v2.37.0 regression-shaped pair that must fail with
    NESTED_DICT_LOSS at result.context.error.diagnosis._meta

Cluster mode fetches /api/executions/<id> and compares nested dictionary
key sets among terminal events for each step. The first terminal event in
a step group is treated as the live projection source, and later terminal
events for that step must retain the same nested control dictionaries.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Any, Iterable

import requests


TERMINAL_EVENT_TYPES = {
    "call.done",
    "call.error",
    "step.exit",
    "command.completed",
    "command.failed",
    "command.cancelled",
}


@dataclass
class ParityIssue:
    code: str
    path: str
    detail: str

    def render(self) -> str:
        return f"{self.code} at {self.path}: {self.detail}"


def _dig(value: Any, path: str) -> Any:
    current = value
    if not path:
        return current
    for part in path.split("."):
        if not isinstance(current, dict):
            return None
        current = current.get(part)
    return current


def _nested_dict_paths(value: Any, prefix: str = "") -> dict[str, set[str]]:
    paths: dict[str, set[str]] = {}
    if not isinstance(value, dict):
        return paths

    for key, child in value.items():
        child_path = f"{prefix}.{key}" if prefix else str(key)
        if isinstance(child, dict):
            paths[child_path] = {str(k) for k in child.keys()}
            paths.update(_nested_dict_paths(child, child_path))
        elif isinstance(child, list):
            for idx, item in enumerate(child):
                if isinstance(item, dict):
                    list_path = f"{child_path}.{idx}"
                    paths[list_path] = {str(k) for k in item.keys()}
                    paths.update(_nested_dict_paths(item, list_path))
    return paths


def compare_nested_dict_keys(live: dict[str, Any], persisted: dict[str, Any]) -> list[ParityIssue]:
    live_paths = _nested_dict_paths(live)
    persisted_paths = _nested_dict_paths(persisted)
    issues: list[ParityIssue] = []

    for path, live_keys in sorted(live_paths.items()):
        persisted_value = _dig(persisted, path)
        if not isinstance(persisted_value, dict):
            code = (
                "NESTED_DICT_LOSS"
                if path == "result.context.error.diagnosis"
                or path.startswith("result.context.error.diagnosis.")
                else "NESTED_DICT_MISSING"
            )
            issues.append(
                ParityIssue(
                    code=code,
                    path=path,
                    detail=f"live keys {sorted(live_keys)} are missing from persisted event",
                )
            )
            continue
        missing_keys = live_keys - {str(k) for k in persisted_value.keys()}
        if missing_keys:
            issues.append(
                ParityIssue(
                    code="NESTED_DICT_KEY_LOSS",
                    path=path,
                    detail=f"missing keys {sorted(missing_keys)}",
                )
            )
    return issues


def _event_result(event: dict[str, Any]) -> dict[str, Any]:
    result = event.get("result")
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except json.JSONDecodeError:
            result = None
    return result if isinstance(result, dict) else {}


def static_smoke() -> int:
    live_ok = {
        "result": {
            "status": "ERROR",
            "context": {
                "error": {
                    "kind": "subflow_failed",
                    "message": "subflow failed",
                    "diagnosis": {
                        "category": "runtime",
                        "confidence": 0.91,
                        "root_cause": "synthetic failure",
                        "suggested_action": "inspect failed subflow",
                        "source": "ollama",
                        "_meta": {
                            "diagnosis_fetch": {
                                "poll_count": 3,
                                "elapsed_seconds": 1.42,
                                "deadline_seconds": 60.0,
                                "hit_deadline": False,
                            }
                        },
                    },
                }
            },
        }
    }
    persisted_ok = json.loads(json.dumps(live_ok))
    persisted_bad = json.loads(json.dumps(live_ok))
    persisted_bad["result"]["context"]["error"].pop("diagnosis")
    persisted_meta_bad = json.loads(json.dumps(live_ok))
    persisted_meta_bad["result"]["context"]["error"]["diagnosis"].pop("_meta")

    ok_issues = compare_nested_dict_keys(live_ok, persisted_ok)
    if ok_issues:
        print("FAIL static v2.35.9-shaped fixture")
        for issue in ok_issues:
            print(issue.render())
        return 1
    print("OK static v2.35.9-shaped fixture preserves nested diagnosis")

    bad_issues = compare_nested_dict_keys(live_ok, persisted_bad)
    expected = any(
        issue.code == "NESTED_DICT_LOSS" and issue.path == "result.context.error.diagnosis"
        for issue in bad_issues
    )
    if not expected:
        print("FAIL static v2.35.8-regression fixture did not detect diagnosis loss")
        for issue in bad_issues:
            print(issue.render())
        return 1
    print("OK static v2.35.8-regression fixture detected NESTED_DICT_LOSS at result.context.error.diagnosis")

    meta_bad_issues = compare_nested_dict_keys(live_ok, persisted_meta_bad)
    expected_meta_loss = any(
        issue.code == "NESTED_DICT_LOSS" and issue.path == "result.context.error.diagnosis._meta"
        for issue in meta_bad_issues
    )
    if not expected_meta_loss:
        print("FAIL static v2.37.0-regression fixture did not detect diagnosis _meta loss")
        for issue in meta_bad_issues:
            print(issue.render())
        return 1
    print("OK static v2.37.0-regression fixture detected NESTED_DICT_LOSS at result.context.error.diagnosis._meta")
    print("3/3 live-vs-persisted parity static checks passed")
    return 0


def _events_from_execution_doc(doc: dict[str, Any]) -> list[dict[str, Any]]:
    events = doc.get("events")
    if isinstance(events, list):
        return [event for event in events if isinstance(event, dict)]
    data = doc.get("data")
    if isinstance(data, dict) and isinstance(data.get("events"), list):
        return [event for event in data["events"] if isinstance(event, dict)]
    return []


def cluster_smoke(base_url: str, execution_id: str) -> int:
    url = f"{base_url.rstrip('/')}/api/executions/{execution_id}?page_size=500"
    response = requests.get(url, timeout=20)
    response.raise_for_status()
    doc = response.json()
    events = _events_from_execution_doc(doc)
    if not events:
        print(f"FAIL cluster parity: no events returned for execution {execution_id}")
        return 1

    terminal_events = [
        event
        for event in events
        if str(event.get("event_type") or event.get("name") or "") in TERMINAL_EVENT_TYPES
    ]
    if not terminal_events:
        print(f"FAIL cluster parity: no terminal step events found for execution {execution_id}")
        return 1

    groups: dict[str, list[dict[str, Any]]] = {}
    for event in terminal_events:
        step = str(event.get("node_name") or event.get("node_id") or event.get("step") or "<unknown>")
        groups.setdefault(step, []).append(event)

    all_issues: list[str] = []
    compared = 0
    for step, group in groups.items():
        ordered = sorted(group, key=lambda event: int(event.get("event_id") or 0))
        live_result = {"result": _event_result(ordered[0])}
        for event in ordered[1:]:
            persisted_result = {"result": _event_result(event)}
            issues = compare_nested_dict_keys(live_result, persisted_result)
            if issues:
                event_type = str(event.get("event_type") or event.get("name") or "")
                for issue in issues:
                    all_issues.append(f"{step}/{event_type}: {issue.render()}")
            compared += 1

    if all_issues:
        print(f"FAIL cluster parity for execution {execution_id}")
        for issue in all_issues:
            print(issue)
        return 1

    print(
        f"OK cluster parity for execution {execution_id}: "
        f"{len(terminal_events)} terminal events, {compared} comparisons"
    )
    return 0


def main(argv: Iterable[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execution-id", help="Execution id to validate through /api/executions/<id>")
    parser.add_argument("--base-url", default="http://localhost:8082", help="NoETL server base URL")
    parser.add_argument("--static", action="store_true", help="Run static fixture checks")
    args = parser.parse_args(list(argv))

    if args.execution_id:
        return cluster_smoke(args.base_url, args.execution_id)
    return static_smoke()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
