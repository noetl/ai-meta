import re

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "r") as f:
    text = f.read()

replacement = """                        _pinned_epoch_id = (
                            str(pinned_loop_epoch_id)
                            if pinned_loop_epoch_id
                            else None
                        )
                        event_id_candidates = []
                        if _pinned_epoch_id:
                            # Epoch is pinned from the command: skip stale candidate resolution.
                            event_id_candidates.append(_pinned_epoch_id)
                            # Add exec fallback only (not step_event_ids which may be stale).
                            exec_fallback = f"exec_{state.execution_id}"
                            if exec_fallback not in event_id_candidates:
                                event_id_candidates.append(exec_fallback)
                        else:
                            if payload_loop_event_id:
                                event_id_candidates.append(str(payload_loop_event_id))
                            for candidate in self._build_loop_event_id_candidates(
                                state, parent_step, loop_state
                            ):
                                if candidate not in event_id_candidates:
                                    event_id_candidates.append(candidate)
                        resolved_loop_event_id = (
                            event_id_candidates[0]
                            if event_id_candidates
                            else f"exec_{state.execution_id}"
                        )

                        import time
                        import logging
                        log = logging.getLogger(__name__)
                        t_term_0 = time.perf_counter()

                        iteration_terminal_claim: Optional[bool] = True
                        if loop_iteration_index is not None and hasattr(nats_cache, "try_record_loop_iteration_terminal"):
                            iteration_terminal_claim = await nats_cache.try_record_loop_iteration_terminal(
                                str(state.execution_id),
                                parent_step,
                                int(loop_iteration_index),
                                event_id=str(resolved_loop_event_id),
                                command_id=_extract_command_id_from_event_payload(
                                    normalized_payload,
                                    event.meta,
                                ),
                            )
                        
                        t_term_1 = time.perf_counter()
                        log.info(f"[PERF] try_record_loop_iteration_terminal took {(t_term_1 - t_term_0)*1000:.1f}ms for index {loop_iteration_index}")
"""
text = re.sub(r'                        _pinned_epoch_id = \(\n                            str\(pinned_loop_epoch_id\)\n                            if pinned_loop_epoch_id\n                            else None\n                        \)\n                        event_id_candidates = \[\]\n                        if _pinned_epoch_id:\n                            # Epoch is pinned from the command: skip stale candidate resolution\.\n                            event_id_candidates\.append\(_pinned_epoch_id\)\n                            # Add exec fallback only \(not step_event_ids which may be stale\)\.\n                            exec_fallback = f"exec_\{state\.execution_id\}"\n                            if exec_fallback not in event_id_candidates:\n                                event_id_candidates\.append\(exec_fallback\)\n                        else:\n                            if payload_loop_event_id:\n                                event_id_candidates\.append\(str\(payload_loop_event_id\)\)\n                            for candidate in self\._build_loop_event_id_candidates\(\n                                state, parent_step, loop_state\n                            \):\n                                if candidate not in event_id_candidates:\n                                    event_id_candidates\.append\(candidate\)\n                        resolved_loop_event_id = \(\n                            event_id_candidates\[0\]\n                            if event_id_candidates\n                            else f"exec_\{state\.execution_id\}"\n                        \)\n\n                        iteration_terminal_claim: Optional\[bool\] = True\n                        if loop_iteration_index is not None and hasattr\(nats_cache, "try_record_loop_iteration_terminal"\):\n                            iteration_terminal_claim = await nats_cache\.try_record_loop_iteration_terminal\(\n                                str\(state\.execution_id\),\n                                parent_step,\n                                int\(loop_iteration_index\),\n                                event_id=str\(resolved_loop_event_id\),\n                                command_id=_extract_command_id_from_event_payload\(\n                                    normalized_payload,\n                                    event\.meta,\n                                \),\n                            \)', replacement, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "w") as f:
    f.write(text)

