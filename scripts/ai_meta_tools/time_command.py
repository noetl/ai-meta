import time
from pydantic import BaseModel
from typing import Any, Optional

class ToolCall(BaseModel):
    kind: str
    config: dict[str, Any]

class CommandSpec(BaseModel):
    next_mode: str = "parallel"

class Command(BaseModel):
    execution_id: str
    step: str
    tool: ToolCall
    input: Optional[dict[str, Any]] = None
    render_context: dict[str, Any] = {}
    pipeline: Optional[list[dict[str, Any]]] = None
    next_targets: Optional[list[dict[str, Any]]] = None
    spec: CommandSpec
    attempt: int = 1
    priority: int = 0
    metadata: dict[str, Any] = {}

pipeline = [{"name": f"task_{i}", "kind": "noop"} for i in range(4)]
context = {"a": [1]*1000}

t0 = time.time()
for _ in range(500):
    Command(
        execution_id="123",
        step="test",
        tool=ToolCall(kind="task_sequence", config={"tasks": pipeline}),
        render_context=context,
        pipeline=pipeline,
        spec=CommandSpec()
    )
print(f"Command 500x: {time.time() - t0:.3f}s")
