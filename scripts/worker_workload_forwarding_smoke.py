"""Smoke for auto-troubleshoot workload key forwarding.

This catches the v2.35.9 compatibility-mirror bug: the agent executor
forwarded deprecated `ollama_*` on_failure keys to diagnose_execution,
but dropped the canonical `triage_*` keys. The smoke dispatches a
diagnose sub-execution with only triage_* backend knobs and verifies
they reach the child input while unrelated secret-like keys stay out.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import types


def _stub(name, **attrs):
    mod = types.ModuleType(name)
    for key, value in attrs.items():
        setattr(mod, key, value)
    sys.modules[name] = mod
    return mod


class _JinjaEnv:
    pass


def _render_template(env, payload, ctx):
    return payload


class _Logger:
    def info(self, *a, **kw): pass
    def warning(self, *a, **kw): pass
    def error(self, *a, **kw): pass
    def debug(self, *a, **kw): pass
    def exception(self, *a, **kw): pass


_stub("jinja2", Environment=_JinjaEnv)
_stub("noetl")
_stub("noetl.core")
_stub("noetl.core.dsl")
_stub("noetl.core.dsl.render", render_template=_render_template)
_stub("noetl.core.logger", setup_logger=lambda *a, **kw: _Logger())
_stub("noetl.core.workflow")
playbook_pkg = _stub("noetl.core.workflow.playbook")


DISPATCH_CALLS: list[dict] = []


def _fake_execute_playbook_task(task_config, context, jinja_env, task_with):
    DISPATCH_CALLS.append({
        "task_config": dict(task_config),
        "task_with": dict(task_with or {}),
    })
    return {"status": "success", "execution_id": "diagnosis-exec-1"}


playbook_pkg.execute_playbook_task = _fake_execute_playbook_task


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent / "repos" / "noetl"
TARGET = REPO_ROOT / "noetl" / "tools" / "agent" / "executor.py"


def _load_executor():
    spec = importlib.util.spec_from_file_location("noetl.tools.agent.executor", TARGET)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


executor = _load_executor()
executor._wait_for_sub_execution_terminal = lambda *a, **kw: {
    "status": "COMPLETED",
    "execution_id": "diagnosis-exec-1",
    "completed": True,
    "failed": False,
}
executor._fetch_persisted_diagnosis_from_doc = lambda *a, **kw: {
    "category": "auth",
    "confidence": 0.91,
    "root_cause": "missing credentials",
    "suggested_action": "configure Workload Identity",
    "source": "vertex-ai",
}


def main() -> int:
    diagnosis = executor._dispatch_troubleshoot_diagnosis(
        failed_execution_id="failed-exec-1",
        failed_entrypoint="tests/spike/spike_failing_subflow",
        troubleshoot_path="automation/agents/troubleshoot/diagnose_execution",
        task_config={
            "on_failure": {
                "troubleshoot": True,
                "triage_model": "gemini-2.5-flash",
                "triage_mcp_server": "mcp/vertex-ai",
                "triage_mcp_endpoint": "https://vertex.example/jsonrpc",
                "triage_mcp_tool": "chat_completion",
                "confidence_threshold": 0.2,
                "escalate_to": "none",
                "noetl_url": "http://noetl.noetl.svc.cluster.local:8082",
                "secret_token": "do-not-forward",
            },
        },
        context={},
        jinja_env=_JinjaEnv(),
    )

    assert diagnosis and diagnosis["source"] == "vertex-ai"
    assert len(DISPATCH_CALLS) == 1
    child_input = DISPATCH_CALLS[0]["task_config"]["input"]

    checks = [
        child_input.get("execution_id") == "failed-exec-1",
        child_input.get("triage_model") == "gemini-2.5-flash",
        child_input.get("triage_mcp_server") == "mcp/vertex-ai",
        child_input.get("triage_mcp_endpoint") == "https://vertex.example/jsonrpc",
        child_input.get("triage_mcp_tool") == "chat_completion",
        child_input.get("confidence_threshold") == 0.2,
        child_input.get("escalate_to") == "none",
        "secret_token" not in child_input,
    ]

    for index, passed in enumerate(checks, start=1):
        assert passed, f"check {index} failed; child_input={child_input!r}"

    print("OK 8/8 worker workload forwarding smoke")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
