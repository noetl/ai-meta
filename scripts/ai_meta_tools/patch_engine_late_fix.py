import re

with open("repos/noetl/noetl/core/dsl/v2/engine.py", "r") as f:
    content = f.read()

# For TASK_SEQ-LOOP
task_seq_pattern = """
                        if is_late_arrival:
                            logger.info(
                                f"[TASK_SEQ-LOOP] Late call.done for {parent_step} epoch {resolved_loop_event_id} "
                                f"(active: {loop_state.get('event_id')}) — detaching loop_state"
                            )
                            loop_state = dict(loop_state)
                        
                        loop_state["event_id"] = resolved_loop_event_id
"""
task_seq_repl = """
                        if is_late_arrival:
                            logger.info(
                                f"[TASK_SEQ-LOOP] Late call.done for {parent_step} epoch {resolved_loop_event_id} "
                                f"(active: {loop_state.get('event_id')}) — detaching loop_state"
                            )
                            loop_state = dict(loop_state)
                        else:
                            loop_state["event_id"] = resolved_loop_event_id
"""
content = content.replace(task_seq_pattern, task_seq_repl)

# For LOOP-CALL.DONE
loop_call_pattern = """
                    if is_late_arrival:
                        logger.info(
                            f"[LOOP-CALL.DONE] Late call.done for {event.step} epoch {resolved_loop_event_id} "
                            f"(active: {loop_state.get('event_id')}) — detaching loop_state"
                        )
                        loop_state = dict(loop_state)

                    loop_state["event_id"] = resolved_loop_event_id
"""
loop_call_repl = """
                    if is_late_arrival:
                        logger.info(
                            f"[LOOP-CALL.DONE] Late call.done for {event.step} epoch {resolved_loop_event_id} "
                            f"(active: {loop_state.get('event_id')}) — detaching loop_state"
                        )
                        loop_state = dict(loop_state)
                    else:
                        loop_state["event_id"] = resolved_loop_event_id
"""
content = content.replace(loop_call_pattern, loop_call_repl)

with open("repos/noetl/noetl/core/dsl/v2/engine.py", "w") as f:
    f.write(content)
