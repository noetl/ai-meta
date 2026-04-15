import re

path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(path, "r") as f:
    text = f.read()

# Pass __loop_continue=True to _issue_loop_commands during the Task Sequence inner-loop iteration dispatch!
old_block = """                            logger.info(
                                f"[TASK_SEQ-LOOP] Issuing iteration commands for {parent_step}: "
                                f"{new_count}/{collection_size} (mode={parent_step_def.loop.mode})"
                            )
                            next_cmds = await self._issue_loop_commands(
                                state,
                                parent_step_def,
                                {"__loop_continue": True},
                            )"""

# I ALREADY DO PASS IT!
