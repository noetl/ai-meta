import re

with open("repos/noetl/noetl/core/dsl/v2/engine.py", "r") as f:
    content = f.read()

# Replace TASK_SEQ-LOOP fallthrough
task_seq_fallthrough = '''
                                if not _skip_loop_done:
                                    # Loop done - mark completed and create loop.done event
                                    loop_state["completed"] = True
                                    loop_state["aggregation_finalized"] = True
'''
task_seq_fallthrough_repl = '''
                                if not _skip_loop_done and not is_late_arrival:
                                    # Loop done - mark completed and create loop.done event
                                    loop_state["completed"] = True
                                    loop_state["aggregation_finalized"] = True
'''
content = content.replace(task_seq_fallthrough.strip('\n'), task_seq_fallthrough_repl.strip('\n'))

# Replace LOOP-CALL.DONE fallthrough
loop_call_fallthrough = '''
                            if not _skip_loop_done:
                                loop_state["completed"] = True
                                loop_state["aggregation_finalized"] = True
'''
loop_call_fallthrough_repl = '''
                            if not _skip_loop_done and not is_late_arrival:
                                loop_state["completed"] = True
                                loop_state["aggregation_finalized"] = True
'''
content = content.replace(loop_call_fallthrough.strip('\n'), loop_call_fallthrough_repl.strip('\n'))

with open("repos/noetl/noetl/core/dsl/v2/engine.py", "w") as f:
    f.write(content)

