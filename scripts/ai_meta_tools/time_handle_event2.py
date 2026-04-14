import re
with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "r") as f:
    text = f.read()

replacement = """                    import time
                    t_start_loop = time.time()
                    for i in range(max_in_flight):
                        t0 = time.time()
                        cmd = await self._create_command_for_step(
                            state, parent_step_def, context, {"__loop_collection": collection}
                        )
                        t_end = time.time()
                        if cmd:
                            commands_to_issue.append(cmd)
                            logger.info(f"[PERF] _create_command_for_step (i={i}) SUCCESS took {t_end - t0:.3f}s")
                        else:
                            logger.info(f"[PERF] _create_command_for_step (i={i}) BREAK took {t_end - t0:.3f}s")
                            break
                    logger.info(f"[PERF] Entire loop of {max_in_flight} took {time.time() - t_start_loop:.3f}s")
"""

pattern = r"""                    for i in range\(max_in_flight\):\n                        cmd = await self._create_command_for_step\(\n                            state, parent_step_def, context, \{"__loop_collection": collection\}\n                        \)\n                        if cmd:\n                            commands_to_issue.append\(cmd\)\n                        else:\n                            break"""
text = re.sub(pattern, replacement, text, flags=re.DOTALL)

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "w") as f:
    f.write(text)
print("Updated events.py for perf tracking")
