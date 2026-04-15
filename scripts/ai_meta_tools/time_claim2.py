import re

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "r") as f:
    text = f.read()

replacement = """                    import time
                    import logging
                    log = logging.getLogger(__name__)
                    t0 = time.perf_counter()
                    claimed_index = await nats_cache.claim_next_loop_index(
                        str(state.execution_id),
                        step.step,
                        collection_size=len(collection),
                        max_in_flight=max_in_flight,
                        event_id=resolved_loop_event_id,
                    )
                    t1 = time.perf_counter()
                    log.info(f"[PERF] nats_cache.claim_next_loop_index took {(t1-t0)*1000:.1f}ms")"""

text = re.sub(r'                    import time\n                    t0 = time\.perf_counter\(\)\n                    claimed_index = await nats_cache\.claim_next_loop_index\(\n                        str\(state\.execution_id\),\n                        step\.step,\n                        collection_size=len\(collection\),\n                        max_in_flight=max_in_flight,\n                        event_id=resolved_loop_event_id,\n                    \)\n                    t1 = time\.perf_counter\(\)\n                    logger\.info\(f"\[PERF\] nats_cache\.claim_next_loop_index took \{\(t1-t0\)\*1000:\.1f\}ms"\)', replacement, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/commands.py", "w") as f:
    f.write(text)

