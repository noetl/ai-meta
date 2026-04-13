import re

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    content = f.read()

# Make sure _evaluate_pending_actions signature is changed and the query is correct
content = re.sub(
    r'    async def _evaluate_pending_actions\(self, state: ExecutionState\) -> list\[Command\]:.*?row = await cur\.fetchone\(\)',
    '    async def _evaluate_pending_actions(self, state: ExecutionState, conn=None) -> list[Command]:\n        pending_count = len(state.issued_steps)\n        if not pending_count:\n            if conn is None:\n                async with get_pool_connection() as c:\n                    async with c.cursor() as cur:\n                        await cur.execute("SELECT COUNT(*) FROM noetl.event WHERE execution_id = %s AND event_type IN (\'command.issued\', \'loop.item\') AND status = \'PENDING\'", (int(state.execution_id),))\n                        row = await cur.fetchone()\n                        pending_count = row[0] if row else 0\n            else:\n                async with conn.cursor() as cur:\n                    await cur.execute("SELECT COUNT(*) FROM noetl.event WHERE execution_id = %s AND event_type IN (\'command.issued\', \'loop.item\') AND status = \'PENDING\'", (int(state.execution_id),))\n                    row = await cur.fetchone()\n                    pending_count = row[0] if row else 0',
    content,
    flags=re.DOTALL
)

# Fix callers of _evaluate_pending_actions in events.py
content = content.replace(
    'await self._evaluate_pending_actions(state)',
    'await self._evaluate_pending_actions(state, conn)'
)

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.write(content)

