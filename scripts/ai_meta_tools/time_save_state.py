import re

with open("repos/noetl/noetl/core/dsl/engine/executor/store.py", "r") as f:
    text = f.read()

replacement = """    async def save_state(self, state: ExecutionState, conn=None):
        import time
        import logging
        log = logging.getLogger(__name__)
        t0 = time.perf_counter()
        
        state_dict = state.to_dict()
        t1 = time.perf_counter()
        
        last_event_id = state.last_event_id"""

text = re.sub(r'    async def save_state\(self, state: ExecutionState, conn=None\):\n        """Save execution state to Postgres execution table\."""\n        state_dict = state\.to_dict\(\)\n        last_event_id = state\.last_event_id', replacement, text)

replacement2 = """        import json
        t2 = time.perf_counter()
        json_str = json.dumps(state_dict)
        t3 = time.perf_counter()
        params = (json_str, status, status, last_event_id, int(state.execution_id))
"""
text = re.sub(r'        params = \(json\.dumps\(state_dict\), status, status, last_event_id, int\(state\.execution_id\)\)', replacement2, text)

replacement3 = """        else:
            async with conn.cursor() as cur:
                await cur.execute(sql, params)
                
        t4 = time.perf_counter()
        log.info(f"[PERF] save_state total={t4-t0:.3f}s to_dict={t1-t0:.3f}s dumps={t3-t2:.3f}s db={t4-t3:.3f}s")
"""
text = re.sub(r'        else:\n            async with conn\.cursor\(\) as cur:\n                await cur\.execute\(sql, params\)', replacement3, text)

with open("repos/noetl/noetl/core/dsl/engine/executor/store.py", "w") as f:
    f.write(text)

