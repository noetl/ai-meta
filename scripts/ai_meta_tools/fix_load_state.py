import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

content = content.replace(
    'async def load_state(self, execution_id: str) -> Optional[ExecutionState]:',
    'async def load_state(self, execution_id: str, conn=None) -> Optional[ExecutionState]:'
)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

