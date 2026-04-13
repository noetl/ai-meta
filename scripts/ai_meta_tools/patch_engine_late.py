import re

with open("repos/noetl/noetl/core/dsl/v2/engine.py", "r") as f:
    content = f.read()

# Replace TASK_SEQ-LOOP state mutations
task_seq_mutations = '''
                                        # did NOT fire loop.done has completed=False in its in-memory
                                        # loop_state and completed_steps, causing it to block the
                                        # re-dispatch via the issued_steps dedup guard.
                                        loop_state["completed"] = True
                                        loop_state["aggregation_finalized"] = True
                                        state.mark_step_completed(
                                            parent_step,
                                            state.get_loop_aggregation(parent_step),
                                        )

                                        # [CLAIM-RECOVERY] If the claim was lost (claimed in KV but event never persisted),
                                        # proceed with the transition anyway to avoid stalling the workflow.
                                        # Or if we just successfully pulled the claim, we shouldn't skip. Wait,
                                        # the problem is that `loop_done_commands` is NOT appended to `commands` in the 
                                        # Recovery branch if `_skip_loop_done` is flipped to False!
                                        # Ah! No, it falls through to `if not _skip_loop_done:`.
                                        if not _is_loop_epoch_transition_emitted(
                                            state, parent_step, "loop.done", resolved_loop_event_id
                                        ):
'''

task_seq_mutations_repl = '''
                                        # did NOT fire loop.done has completed=False in its in-memory
                                        # loop_state and completed_steps, causing it to block the
                                        # re-dispatch via the issued_steps dedup guard.
                                        if not is_late_arrival:
                                            loop_state["completed"] = True
                                            loop_state["aggregation_finalized"] = True
                                            state.mark_step_completed(
                                                parent_step,
                                                state.get_loop_aggregation(parent_step),
                                            )

                                        # [CLAIM-RECOVERY] If the claim was lost (claimed in KV but event never persisted),
                                        # proceed with the transition anyway to avoid stalling the workflow.
                                        # Or if we just successfully pulled the claim, we shouldn't skip. Wait,
                                        # the problem is that `loop_done_commands` is NOT appended to `commands` in the 
                                        # Recovery branch if `_skip_loop_done` is flipped to False!
                                        # Ah! No, it falls through to `if not _skip_loop_done:`.
                                        if not is_late_arrival and not _is_loop_epoch_transition_emitted(
                                            state, parent_step, "loop.done", resolved_loop_event_id
                                        ):
'''
content = content.replace(task_seq_mutations.strip('\n'), task_seq_mutations_repl.strip('\n'))

# Replace LOOP-CALL.DONE state mutations
loop_call_mutations = '''
                                    # Update local state so subsequent routing from a
                                    # loopback step (e.g. load_patients → fetch_assessments
                                    # epoch 2) is not blocked by the issued_steps dedup guard
                                    # on this pod, which did not fire loop.done itself.
                                    loop_state["completed"] = True
                                    loop_state["aggregation_finalized"] = True
                                    state.mark_step_completed(
                                        event.step,
                                        state.get_loop_aggregation(event.step),
                                    )

                                    # [CLAIM-RECOVERY] If the claim was lost (claimed in KV but event never persisted),
                                    # proceed with the transition anyway to avoid stalling the workflow.
                                    if not _is_loop_epoch_transition_emitted(
                                        state, event.step, "loop.done", resolved_loop_event_id
                                    ):
'''

loop_call_mutations_repl = '''
                                    # Update local state so subsequent routing from a
                                    # loopback step (e.g. load_patients → fetch_assessments
                                    # epoch 2) is not blocked by the issued_steps dedup guard
                                    # on this pod, which did not fire loop.done itself.
                                    if not is_late_arrival:
                                        loop_state["completed"] = True
                                        loop_state["aggregation_finalized"] = True
                                        state.mark_step_completed(
                                            event.step,
                                            state.get_loop_aggregation(event.step),
                                        )

                                    # [CLAIM-RECOVERY] If the claim was lost (claimed in KV but event never persisted),
                                    # proceed with the transition anyway to avoid stalling the workflow.
                                    if not is_late_arrival and not _is_loop_epoch_transition_emitted(
                                        state, event.step, "loop.done", resolved_loop_event_id
                                    ):
'''
content = content.replace(loop_call_mutations.strip('\n'), loop_call_mutations_repl.strip('\n'))

with open("repos/noetl/noetl/core/dsl/v2/engine.py", "w") as f:
    f.write(content)

