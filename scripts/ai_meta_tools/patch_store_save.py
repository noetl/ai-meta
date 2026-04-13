import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

content = content.replace(
    "async def save_state(self, state: ExecutionState):",
    "async def save_state(self, state: ExecutionState, conn=None):"
)

content = content.replace(
    "async with get_pool_connection() as conn:",
    "if conn is None:\n            # Fallback if no conn provided\n            async with get_pool_connection() as c:\n                async with c.cursor() as cur:\n                    await cur.execute(\n                        \"UPDATE noetl.execution SET state = %s, updated_at = CURRENT_TIMESTAMP WHERE execution_id = %s\",\n                        (json.dumps(state_dict), int(state.execution_id))\n                    )\n        else:\n            async with conn.cursor() as cur:\n                await cur.execute(\n                    \"UPDATE noetl.execution SET state = %s, updated_at = CURRENT_TIMESTAMP WHERE execution_id = %s\",\n                    (json.dumps(state_dict), int(state.execution_id))\n                )"
)

# And remove the extra execute block I just replaced
content = re.sub(
    r'async with get_pool_connection.*?logger\.debug\(f"\[STATE-SAVE\]',
    'logger.debug(f"[STATE-SAVE]',
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

