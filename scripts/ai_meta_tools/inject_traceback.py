import os
import re

file_path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(file_path, "r") as f:
    text = f.read()

# Wrap handle_event body in try...except
old_start = '        logger.debug(\n            "[ENGINE] handle_event called: event.name=%s, step=%s, execution=%s, already_persisted=%s",\n            event.name,\n            event.step,\n            event.execution_id,\n            already_persisted,\n        )'

new_start = old_start + '\n        import traceback\n        try:'

# Find the end of the method (it returns commands)
# This is a bit risky with regex, so I'll just append the except at the very end of the class or file
# but handle_event is a method of ControlFlowEngine.

# Let's use a simpler approach: wrap the specific transition evaluation
text = text.replace(
    "commands = await self._process_event(state, event, conn)",
    """import traceback
        try:
            commands = await self._process_event(state, event, conn)
        except Exception as e:
            logger.critical(f"FATAL ENGINE ERROR during _process_event: {e}\\n{traceback.format_exc()}")
            raise e"""
)

with open(file_path, "w") as f:
    f.write(text)
print("Successfully injected traceback logging into events.py")
