import re
with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "r") as f:
    text = f.read()

replacement = """
                if _is_loop:
                    # Loop step -> spawn multiple iterations
                    import time
                    max_in_flight = 1
                    # ... get max in flight
                    if parent_step_def.loop and parent_step_def.loop.spec and parent_step_def.loop.spec.max_in_flight:
                        max_in_flight = max(1, int(parent_step_def.loop.spec.max_in_flight))

                    logger.info(f"[TASK_SEQ-LOOP] Issuing iteration commands for {parent_step}: {_loop_results_total(state.loop_state[parent_step])}/{len(state.loop_state[parent_step].get('collection', []))} (mode={loop_mode})")

                    t_start_loop = time.time()
                    for i in range(max_in_flight):
                        t0 = time.time()
                        cmd = await self._create_command_for_step(
                            state, parent_step_def, context, {"__loop_collection": collection}
                        )
                        t_end_cmd = time.time()
                        if cmd:
                            commands_to_issue.append(cmd)
                            logger.info(f"[PERF] _create_command_for_step (i={i}) SUCCESS took {t_end_cmd - t0:.3f}s")
                        else:
                            logger.info(f"[PERF] _create_command_for_step (i={i}) BREAK took {t_end_cmd - t0:.3f}s")
                            break
                    logger.info(f"[PERF] Loop of {max_in_flight} took {time.time() - t_start_loop:.3f}s")
"""

pattern = r"""
                if _is_loop:
                    # Loop step -> spawn multiple iterations
                    max_in_flight = 1
                    if parent_step_def\.loop and parent_step_def\.loop\.spec and parent_step_def\.loop\.spec\.max_in_flight:
                        max_in_flight = max\(1, int\(parent_step_def\.loop\.spec\.max_in_flight\)\)

                    logger\.info\(
                        "\[TASK_SEQ-LOOP\] Issuing iteration commands for %s: %s/%s \(mode=%s\)",
                        parent_step,
                        _loop_results_total\(state\.loop_state\[parent_step\]\),
                        existing_loop_state\.get\("collection_size", 0\),
                        loop_mode,
                    \)

                    for i in range\(max_in_flight\):
                        cmd = await self\._create_command_for_step\(
                            state, parent_step_def, context, \{"__loop_collection": collection\}
                        \)
                        if cmd:
                            commands_to_issue\.append\(cmd\)
                        else:
                            break
"""
text = re.sub(pattern, replacement, text, flags=re.DOTALL)

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "w") as f:
    f.write(text)
print("Updated events.py for perf tracking")
