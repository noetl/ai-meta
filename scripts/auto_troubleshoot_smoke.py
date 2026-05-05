"""Hand-rolled smoke checks for Gap 4.1's auto-troubleshoot dispatch.

Verifies the executor's behaviour when a `tool: agent framework=noetl`
sub-playbook fails:

- with opt-in OFF (default): error envelope unchanged, no diagnosis
- with task-level opt-in ON: error.diagnosis attached when troubleshoot
  succeeds
- with NOETL_AGENT_AUTO_TROUBLESHOOT env truthy: same behaviour
- per-task false overrides the env (operator can disable per-call)
- recursion guard: troubleshoot path never auto-troubleshoots itself
- diagnostic failure leaves the original error untouched
- no execution_id on the failed sub-playbook → skip diagnosis cleanly

Stubs everything noetl-side via importlib + types.ModuleType.
"""

from __future__ import annotations

import asyncio
import importlib.util
import os
import pathlib
import sys
import types


# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------


def _stub(name: str, **attrs):
    mod = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(mod, k, v)
    sys.modules[name] = mod
    return mod


# jinja2.Environment — only the type is referenced
class _JinjaEnv:
    pass


_stub("jinja2", Environment=_JinjaEnv)


# noetl.core.dsl.render — render_template is called with (env, dict, ctx)
def _render_template(env, payload, ctx):
    return payload  # passthrough — we don't exercise jinja in this test


_stub("noetl")
_stub("noetl.core")
_stub("noetl.core.dsl")
_stub("noetl.core.dsl.render", render_template=_render_template)


# noetl.core.logger — silent
class _Logger:
    def info(self, *a, **kw): pass
    def warning(self, *a, **kw): pass
    def error(self, *a, **kw): pass
    def debug(self, *a, **kw): pass
    def exception(self, *a, **kw): pass


_stub("noetl.core.logger", setup_logger=lambda *a, **kw: _Logger())


# noetl.core.workflow.playbook — execute_playbook_task is the
# dispatch surface we replace with controllable fakes per test.
_workflow_mod = _stub("noetl.core.workflow")
playbook_pkg = _stub("noetl.core.workflow.playbook")


# Test-controllable fake for execute_playbook_task. Each test sets
# this before invoking the agent executor.
_FAKE_DISPATCH_CALLS: list[dict] = []
_FAKE_DISPATCH_RESPONSES: dict[str, dict] = {}


def _fake_execute_playbook_task(task_config, context, jinja_env, task_with):
    """Fake plugin: returns canned responses keyed by playbook path."""
    _FAKE_DISPATCH_CALLS.append({"task_config": dict(task_config), "input": dict(task_with or {})})
    path = task_config.get("path")
    return _FAKE_DISPATCH_RESPONSES.get(path, {"status": "error", "error": "no fake configured"})


playbook_pkg.execute_playbook_task = _fake_execute_playbook_task


# ---------------------------------------------------------------------------
# Load the executor under test
# ---------------------------------------------------------------------------


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent / "repos" / "noetl"
TARGET = REPO_ROOT / "noetl" / "tools" / "agent" / "executor.py"


def _load_executor():
    spec = importlib.util.spec_from_file_location(
        "noetl.tools.agent.executor", TARGET
    )
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


executor = _load_executor()


# ---------------------------------------------------------------------------
# Stub _wait_for_sub_execution_terminal — the smoke fakes
# `execute_playbook_task`'s output, but the production code now polls
# /api/executions/<id>/status to wait for terminal status before
# building the envelope. We don't have a real server in this harness;
# short-circuit by treating every poll as instantly-terminal with the
# completion state implied by the fake's plugin_status.
def _fake_wait_terminal(execution_id, timeout_seconds=None, poll_interval_seconds=None):
    # Test convention: any execution_id starting with "exec-failed"
    # represents a failed sub-execution; everything else completed
    # successfully. The handful of test responses use these prefixes.
    failed = "fail" in str(execution_id).lower()
    return {
        "completed": not failed,
        "failed": failed,
        "execution_id": execution_id,
    }


executor._wait_for_sub_execution_terminal = _fake_wait_terminal


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _reset():
    _FAKE_DISPATCH_CALLS.clear()
    _FAKE_DISPATCH_RESPONSES.clear()
    os.environ.pop("NOETL_AGENT_AUTO_TROUBLESHOOT", None)


def _failed_sub_response(execution_id="exec-failed-1"):
    return {
        "status": "error",
        "data": {"some": "partial-result"},
        "execution_id": execution_id,
        "duration": 1.2,
        "error": "sub-playbook step 'fetch_remote' raised RuntimeError",
    }


def _diagnosis_response():
    return {
        "status": "success",
        "data": {
            "execution_id": "exec-failed-1",
            "category": "transient_5xx",
            "confidence": 0.82,
            "root_cause": "Upstream API returned 502",
            "suggested_action": "Retry; if persistent, check upstream status page",
            "source": "ollama",
            "escalated": False,
        },
        "execution_id": "diag-exec-1",
        "duration": 0.8,
    }


def _invoke(task_config):
    return executor._invoke_noetl_playbook(
        entrypoint=task_config.get("entrypoint", "test/playbook"),
        payload={"foo": "bar"},
        invoke_kwargs={},
        task_config=task_config,
        context={},
        jinja_env=_JinjaEnv(),
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def t_default_off_no_diagnosis():
    _reset()
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = _failed_sub_response()

    rsp = _invoke({"entrypoint": "test/playbook"})

    assert rsp["status"] == "error"
    assert "diagnosis" not in rsp["error"], rsp["error"]
    # Only the sub-playbook was dispatched, not the troubleshoot agent
    paths = [c["task_config"]["path"] for c in _FAKE_DISPATCH_CALLS]
    assert paths == ["test/playbook"], paths
    print("OK 1: default off — no troubleshoot dispatched, no diagnosis attached")


def t_per_task_opt_in_attaches_diagnosis():
    _reset()
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = _failed_sub_response()
    _FAKE_DISPATCH_RESPONSES["automation/agents/troubleshoot/diagnose_execution"] = _diagnosis_response()

    rsp = _invoke({
        "entrypoint": "test/playbook",
        "on_failure": {"troubleshoot": True},
    })

    assert rsp["status"] == "error"
    diag = rsp["error"].get("diagnosis")
    assert isinstance(diag, dict), rsp["error"]
    assert diag["category"] == "transient_5xx"
    assert diag["confidence"] == 0.82
    # Both dispatches happened in order
    paths = [c["task_config"]["path"] for c in _FAKE_DISPATCH_CALLS]
    assert paths == ["test/playbook", "automation/agents/troubleshoot/diagnose_execution"], paths
    # Troubleshoot input carried the failed sub-execution_id
    diag_call = _FAKE_DISPATCH_CALLS[1]
    assert diag_call["input"]["execution_id"] == "exec-failed-1"
    print("OK 2: per-task opt-in attaches diagnosis with failed execution_id")


def t_env_opt_in_attaches_diagnosis():
    _reset()
    os.environ["NOETL_AGENT_AUTO_TROUBLESHOOT"] = "1"
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = _failed_sub_response()
    _FAKE_DISPATCH_RESPONSES["automation/agents/troubleshoot/diagnose_execution"] = _diagnosis_response()

    rsp = _invoke({"entrypoint": "test/playbook"})

    assert rsp["status"] == "error"
    assert "diagnosis" in rsp["error"]
    print("OK 3: NOETL_AGENT_AUTO_TROUBLESHOOT=1 enables auto-dispatch globally")


def t_per_task_false_overrides_env():
    _reset()
    os.environ["NOETL_AGENT_AUTO_TROUBLESHOOT"] = "1"
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = _failed_sub_response()
    _FAKE_DISPATCH_RESPONSES["automation/agents/troubleshoot/diagnose_execution"] = _diagnosis_response()

    rsp = _invoke({
        "entrypoint": "test/playbook",
        "on_failure": {"troubleshoot": False},
    })

    assert rsp["status"] == "error"
    assert "diagnosis" not in rsp["error"]
    paths = [c["task_config"]["path"] for c in _FAKE_DISPATCH_CALLS]
    assert paths == ["test/playbook"], paths
    print("OK 4: per-task troubleshoot=false overrides env opt-in")


def t_recursion_guard_skips_self():
    _reset()
    os.environ["NOETL_AGENT_AUTO_TROUBLESHOOT"] = "1"
    troubleshoot_path = "automation/agents/troubleshoot/diagnose_execution"
    _FAKE_DISPATCH_RESPONSES[troubleshoot_path] = _failed_sub_response()

    rsp = _invoke({"entrypoint": troubleshoot_path})

    assert rsp["status"] == "error"
    assert "diagnosis" not in rsp["error"]
    paths = [c["task_config"]["path"] for c in _FAKE_DISPATCH_CALLS]
    # Only one dispatch — the troubleshoot path itself; no recursive
    # auto-dispatch.
    assert paths == [troubleshoot_path], paths
    print("OK 5: recursion guard skips auto-dispatch when entrypoint is the troubleshoot path")


def t_custom_troubleshoot_path():
    _reset()
    custom = "automation/agents/troubleshoot/custom_diag"
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = _failed_sub_response()
    _FAKE_DISPATCH_RESPONSES[custom] = _diagnosis_response()

    rsp = _invoke({
        "entrypoint": "test/playbook",
        "on_failure": {
            "troubleshoot": True,
            "troubleshoot_path": custom,
            "ollama_model": "qwen2.5:7b",
            "confidence_threshold": 0.85,
        },
    })

    assert "diagnosis" in rsp["error"]
    diag_call = _FAKE_DISPATCH_CALLS[1]
    assert diag_call["task_config"]["path"] == custom
    assert diag_call["input"]["ollama_model"] == "qwen2.5:7b"
    assert diag_call["input"]["confidence_threshold"] == 0.85
    print("OK 6: custom troubleshoot_path + workload knobs flow through on_failure")


def t_diagnosis_failure_leaves_envelope_untouched():
    _reset()
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = _failed_sub_response()
    _FAKE_DISPATCH_RESPONSES["automation/agents/troubleshoot/diagnose_execution"] = {
        "status": "error",
        "error": "ollama unreachable",
    }

    rsp = _invoke({
        "entrypoint": "test/playbook",
        "on_failure": {"troubleshoot": True},
    })

    assert rsp["status"] == "error"
    # No diagnosis attached when the diagnostic itself fails
    assert "diagnosis" not in rsp["error"]
    # Original error message is preserved
    assert "fetch_remote" in rsp["error"]["message"]
    print("OK 7: failed diagnostic leaves original error untouched")


def t_no_execution_id_skips_diagnosis():
    _reset()
    failed = _failed_sub_response(execution_id=None)
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = failed
    _FAKE_DISPATCH_RESPONSES["automation/agents/troubleshoot/diagnose_execution"] = _diagnosis_response()

    rsp = _invoke({
        "entrypoint": "test/playbook",
        "on_failure": {"troubleshoot": True},
    })

    assert "diagnosis" not in rsp["error"]
    # Troubleshoot was NOT dispatched (no execution_id to diagnose)
    paths = [c["task_config"]["path"] for c in _FAKE_DISPATCH_CALLS]
    assert paths == ["test/playbook"], paths
    print("OK 8: missing execution_id on failed sub-playbook skips diagnosis cleanly")


def t_success_never_dispatches_diagnosis():
    _reset()
    _FAKE_DISPATCH_RESPONSES["test/playbook"] = {
        "status": "success",
        "data": {"hello": "world"},
        "execution_id": "exec-ok-1",
    }
    _FAKE_DISPATCH_RESPONSES["automation/agents/troubleshoot/diagnose_execution"] = _diagnosis_response()

    rsp = _invoke({
        "entrypoint": "test/playbook",
        "on_failure": {"troubleshoot": True},
    })

    assert rsp["status"] == "ok"
    paths = [c["task_config"]["path"] for c in _FAKE_DISPATCH_CALLS]
    assert paths == ["test/playbook"], paths
    print("OK 9: successful sub-playbook never dispatches diagnostic, even with opt-in")


t_default_off_no_diagnosis()
t_per_task_opt_in_attaches_diagnosis()
t_env_opt_in_attaches_diagnosis()
t_per_task_false_overrides_env()
t_recursion_guard_skips_self()
t_custom_troubleshoot_path()
t_diagnosis_failure_leaves_envelope_untouched()
t_no_execution_id_skips_diagnosis()
t_success_never_dispatches_diagnosis()
