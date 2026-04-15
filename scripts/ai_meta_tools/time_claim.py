import re

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "r") as f:
    text = f.read()

replacement = """                    import time
                    t0 = time.perf_counter()
                    claimed_index = await nats_cache.claim_next_loop_index(
                        str(state.execution_id),
                        step.step,
                        collection_size=len(collection),
                        max_in_flight=max_in_flight,
                        event_id=resolved_loop_event_id,
                    )
                    t1 = time.perf_counter()
                    logger.info(f"[PERF] nats_cache.claim_next_loop_index took {(t1-t0)*1000:.1f}ms")"""

text = re.sub(r'                    claimed_index = await nats_cache\.claim_next_loop_index\(\n                        str\(state\.execution_id\),\n                        step\.step,\n                        collection_size=len\(collection\),\n                        max_in_flight=max_in_flight,\n                        event_id=resolved_loop_event_id,\n                    \)', replacement, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "w") as f:
    f.write(text)

