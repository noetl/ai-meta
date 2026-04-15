import re

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "r") as f:
    text = f.read()

replacement = """        # Execute state machine transition
        import time
        import logging
        log = logging.getLogger(__name__)
        t0 = time.perf_counter()
        
        commands = await self._process_event(state, event, conn)
        
        t1 = time.perf_counter()
        log.info(f"[PERF] _process_event took {t1 - t0:.3f}s for {event.name}")

        # Add tracking for issued commands to avoid duplicate dispatch
        for cmd in commands:"""

text = re.sub(r'        # Execute state machine transition\n        commands = await self\._process_event\(state, event, conn\)\n\n        # Add tracking for issued commands to avoid duplicate dispatch\n        for cmd in commands:', replacement, text)

replacement2 = """                            logger.info(
                                "[TASK_SEQ-LOOP] Issuing iteration commands for %s: %s/%s (mode=%s)",
                                parent_step,
                                _loop_results_total(state.loop_state[parent_step]),
                                existing_loop_state.get("collection_size", 0),
                                loop_mode,
                            )
                            t3 = time.perf_counter()
                            cmds = await self._issue_loop_commands(state, parent_step_def, context)
                            t4 = time.perf_counter()
                            log.info(f"[PERF] _issue_loop_commands took {t4 - t3:.3f}s")
                            if cmds:
                                commands.extend(cmds)"""

text = re.sub(r'                            logger\.info\(\n                                "\[TASK_SEQ-LOOP\] Issuing iteration commands for %s: %s/%s \(mode=%s\)",\n                                parent_step,\n                                _loop_results_total\(state\.loop_state\[parent_step\]\),\n                                existing_loop_state\.get\("collection_size", 0\),\n                                loop_mode,\n                            \)\n                            cmds = await self\._issue_loop_commands\(state, parent_step_def, context\)\n                            if cmds:\n                                commands\.extend\(cmds\)', replacement2, text)

replacement3 = """            t5 = time.perf_counter()
            await self.state_store.save_state(state, conn)
            t6 = time.perf_counter()
            log.info(f"[PERF] save_state inside loop took {t6 - t5:.3f}s")"""

text = re.sub(r'            await self\.state_store\.save_state\(state, conn\)', replacement3, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "w") as f:
    f.write(text)

