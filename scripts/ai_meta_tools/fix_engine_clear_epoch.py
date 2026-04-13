import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                            if loop_step in loop_iteration_state:
                                loop_iteration_state[loop_step].pop("completed", None)
                                loop_iteration_state[loop_step].pop("aggregation_finalized", None)
                                loop_iteration_state[loop_step]["results"] = []
                                loop_iteration_state[loop_step]["omitted_results_count"] = 0
                                loop_iteration_state[loop_step]["scheduled_count"] = 0
                                loop_iteration_state[loop_step]["failed_count"] = 0
                                loop_iteration_state[loop_step]["index"] = 0
                                state.completed_steps.discard(loop_step)
                                state.step_results.pop(loop_step, None)

                            loop_event_id = meta_data.get("loop_event_id")"""

replacement = """                            loop_event_id = meta_data.get("loop_event_id")
                            # Only reset the epoch state if we are actually crossing into a NEW epoch
                            # (i.e. the loop_event_id has changed from the one we were previously tracking).
                            # Otherwise, we would falsely wipe the array on every single iteration's command.issued!
                            if loop_event_id and str(loop_event_id) != loop_event_ids.get(loop_step):
                                if loop_step in loop_iteration_state:
                                    loop_iteration_state[loop_step].pop("completed", None)
                                    loop_iteration_state[loop_step].pop("aggregation_finalized", None)
                                    loop_iteration_state[loop_step]["results"] = []
                                    loop_iteration_state[loop_step]["omitted_results_count"] = 0
                                    loop_iteration_state[loop_step]["scheduled_count"] = 0
                                    loop_iteration_state[loop_step]["failed_count"] = 0
                                    loop_iteration_state[loop_step]["index"] = 0
                                    state.completed_steps.discard(loop_step)
                                    state.step_results.pop(loop_step, None)"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
