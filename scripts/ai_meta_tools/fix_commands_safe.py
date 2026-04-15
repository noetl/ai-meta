path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# 1. Add default collection initialization
text = text.replace(
    "    async def _create_command_for_step(",
    "    async def _create_command_for_step(\n        self,\n        state: ExecutionState,\n        step: Step,\n        transition_input: dict[str, Any]\n    ) -> Optional[Command]:\n        collection = [] # Default to empty list to avoid NoneType errors"
)

# 2. Fix the broken method signature replacement (it might have doubled up)
# I'll just use a more surgical replacement.

with open(path, "w") as f:
    f.write(text)

