import time
from noetl.core.dsl.engine.models.workflow import Playbook
from noetl.core.dsl.engine.models.commands import Command, ToolCall, CommandSpec

playbook_data = {
  "apiVersion": "noetl.io/v2",
  "kind": "Playbook",
  "metadata": {"name": "test_pft_flow"},
  "workflow": [{"step": f"step_{i}", "tool": {"kind": "noop"}} for i in range(100)]
}

playbook = Playbook(**playbook_data)

context = {"playbook": playbook, "variables": {"a": 1}}

t0 = time.time()
for _ in range(20):
    cmd = Command(
        execution_id="123",
        step="test",
        tool=ToolCall(kind="noop", config={}),
        input=None,
        render_context=context,
        pipeline=None,
        next_targets=None,
        spec=CommandSpec(),
        attempt=1,
        priority=0,
        metadata={},
    )
print(f"Command instantiation 20 times: {time.time() - t0:.3f}s")
