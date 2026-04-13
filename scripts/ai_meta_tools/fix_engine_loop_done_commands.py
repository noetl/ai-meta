import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                                        loop_state["completed"] = True
                                        loop_state["aggregation_finalized"] = True
                                        state.mark_step_completed(
                                            parent_step,
                                            state.get_loop_aggregation(parent_step),
                                        )

                                        # [CLAIM-RECOVERY] If the claim was lost (claimed in KV but event never persisted),
                                        # proceed with the transition anyway to avoid stalling the workflow."""

replacement = """                                        loop_state["completed"] = True
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
                                        # Ah! No, it falls through to `if not _skip_loop_done:`."""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
