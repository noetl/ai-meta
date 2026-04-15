import re

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "r") as f:
    text = f.read()

replacement = """                        elif _pinned_epoch_id:
                            # Worker stamped the event with an explicit epoch ID.
                            # Only try that specific key — if it is gone (TTL expired or
                            # wrong epoch) the event belongs to an old, already-completed
                            # batch and must NOT be credited to the current epoch.
                            t_inc_0 = time.perf_counter()
                            primary_count = await nats_cache.increment_loop_completed(
                                str(state.execution_id),
                                parent_step,
                                event_id=str(_pinned_epoch_id),
                            )
                            t_inc_1 = time.perf_counter()
                            log.info(f"[PERF] increment_loop_completed took {(t_inc_1 - t_inc_0)*1000:.1f}ms")
"""
text = re.sub(r'                        elif _pinned_epoch_id:\n                            # Worker stamped the event with an explicit epoch ID\.\n                            # Only try that specific key — if it is gone \(TTL expired or\n                            # wrong epoch\) the event belongs to an old, already-completed\n                            # batch and must NOT be credited to the current epoch\.\n                            primary_count = await nats_cache\.increment_loop_completed\(\n                                str\(state\.execution_id\),\n                                parent_step,\n                                event_id=str\(_pinned_epoch_id\),\n                            \)', replacement, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "w") as f:
    f.write(text)

