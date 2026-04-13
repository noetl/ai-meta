import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

# Instead of relying on `loop_event_id` from meta, we can recognize a new epoch
# by simply observing ANY `command.issued` for the step, OR we can look at the `payload`
# which contains `loop_event_id` via `context` in the actual rendered `Command`!
# Wait, `load_state` parses `meta_data = row[5] if len(row) > 5 else None`.
# We should ALWAYS clear `completed` when we see a `command.issued` for a loop step,
# regardless of `loop_event_id`.

target = """                        if isinstance(meta_data, dict):
                            loop_event_id = meta_data.get("loop_event_id")
                            if loop_event_id:"""

replacement = """                        if isinstance(meta_data, dict):
                            loop_step = (
                                node_name.replace(":task_sequence", "")
                                if isinstance(node_name, str)
                                else node_name
                            )
                            if loop_step in loop_iteration_state:
                                loop_iteration_state[loop_step].pop("completed", None)
                                loop_iteration_state[loop_step].pop("aggregation_finalized", None)
                                loop_iteration_state[loop_step]["results"] = []
                                loop_iteration_state[loop_step]["omitted_results_count"] = 0
                                loop_iteration_state[loop_step]["scheduled_count"] = 0
                                loop_iteration_state[loop_step]["failed_count"] = 0
                                loop_iteration_state[loop_step]["index"] = 0
                                state.completed_steps.discard(loop_step)
                                state.step_results.pop(loop_step, None)

                            loop_event_id = meta_data.get("loop_event_id")
                            if loop_event_id:
                                loop_iteration_state[loop_step]["event_id"] = str(loop_event_id)
                                loop_event_ids[loop_step] = str(loop_event_id)"""

# I need to clean up my old patch first
old_target = """                            if loop_event_id:
                                loop_step = (
                                    node_name.replace(":task_sequence", "")
                                    if isinstance(node_name, str)
                                    else node_name
                                )
                                loop_event_ids[loop_step] = str(loop_event_id)
                                
                                # CRITICAL FIX: If a loop is re-dispatched (new command.issued),
                                # we are starting a new epoch. Clear any stale aggregation_finalized
                                # flags from previous epochs so the new epoch's results aren't dropped.
                                if loop_step in loop_iteration_state:
                                    loop_iteration_state[loop_step].pop("completed", None)
                                    loop_iteration_state[loop_step].pop("aggregation_finalized", None)
                                    loop_iteration_state[loop_step]["results"] = []
                                    loop_iteration_state[loop_step]["omitted_results_count"] = 0
                                    loop_iteration_state[loop_step]["scheduled_count"] = 0
                                    loop_iteration_state[loop_step]["failed_count"] = 0
                                    loop_iteration_state[loop_step]["index"] = 0
                                    loop_iteration_state[loop_step]["event_id"] = str(loop_event_id)
                                state.completed_steps.discard(loop_step)
                                state.step_results.pop(loop_step, None)"""

if old_target in content:
    content = content.replace(old_target, """                            if loop_event_id:
                                loop_step = (
                                    node_name.replace(":task_sequence", "")
                                    if isinstance(node_name, str)
                                    else node_name
                                )
                                loop_event_ids[loop_step] = str(loop_event_id)""")

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
