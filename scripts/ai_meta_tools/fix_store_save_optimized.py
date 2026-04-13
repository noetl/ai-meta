import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

new_save_state = """    async def save_state(self, state: ExecutionState, conn=None):
        \"\"\"Save execution state to Postgres execution table.\"\"\"
        state_dict = state.to_dict()
        last_event_id = state.last_event_id
        
        # Determine status for SQL update
        status = "FAILED" if state.failed else ("COMPLETED" if state.completed else "RUNNING")
        
        sql = \"\"\"
            UPDATE noetl.execution 
            SET state = %s, 
                updated_at = CURRENT_TIMESTAMP,
                status = CASE 
                    WHEN status IN ('COMPLETED', 'FAILED', 'CANCELLED') THEN status 
                    ELSE %s 
                END,
                last_event_id = GREATEST(COALESCE(last_event_id, 0), %s)
            WHERE execution_id = %s
        \"\"\"
        params = (json.dumps(state_dict), status, last_event_id, int(state.execution_id))
        
        if conn is None:
            async with get_pool_connection() as c:
                async with c.cursor() as cur:
                    await cur.execute(sql, params)
        else:
            async with conn.cursor() as cur:
                await cur.execute(sql, params)

        logger.debug(f"[STATE-SAVE] State saved to Postgres for execution {state.execution_id}")"""

content = re.sub(
    r'    async def save_state\(self, state: ExecutionState, conn=None\):.*?logger\.debug\(f"\[STATE-SAVE\] State saved to Postgres for execution {state\.execution_id}"\)',
    new_save_state,
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

