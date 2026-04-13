import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """        logger.debug(
            "[ENGINE] handle_event called: event.name=%s, step=%s, execution=%s, already_persisted=%s",
            event.name,
            event.step,
            event.execution_id,
            already_persisted,
        )"""

replacement = """        logger.debug(
            "[ENGINE] handle_event called: event.name=%s, step=%s, execution=%s, already_persisted=%s",
            event.name,
            event.step,
            event.execution_id,
            already_persisted,
        )
        if event.name == "call.done" and "task_sequence" in str(event.step):
            logger.error(f"[DEBUG-TRACE-2] ENTERED handle_event for {event.step} id={event.execution_id}")"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
