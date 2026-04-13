import re

# 1. Fix store.py (PlaybookRepo)
with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

# Fix load_playbook
content = content.replace(
    'async def load_playbook(self, path: str) -> Optional[Playbook]:',
    'async def load_playbook(self, path: str, conn=None) -> Optional[Playbook]:'
)
content = content.replace(
    '        async with get_pool_connection() as conn:\n            async with conn.cursor(row_factory=dict_row) as cur:',
    '        if conn is None:\n            async with get_pool_connection() as c:\n                async with c.cursor(row_factory=dict_row) as cur:\n                    await cur.execute("SELECT content FROM noetl.catalog WHERE path = %s LIMIT 1", (path,))\n                    row = await cur.fetchone()\n        else:\n            async with conn.cursor(row_factory=dict_row) as cur:\n                await cur.execute("SELECT content FROM noetl.catalog WHERE path = %s LIMIT 1", (path,))\n                row = await cur.fetchone()\n        if row:'
)
content = re.sub(
    r'        async with get_pool_connection\(\) as conn:\n            async with conn\.cursor\(row_factory=dict_row\) as cur:\n                await cur\.execute\(\n                    "SELECT content FROM noetl\.catalog WHERE path = %s LIMIT 1",\n                    \(path,\)\n                \)\n                row = await cur\.fetchone\(\)\n\n        if row:',
    '',
    content,
    flags=re.DOTALL
)

# Fix load_playbook_by_id
content = content.replace(
    'async def load_playbook_by_id(self, catalog_id: int) -> Optional[Playbook]:',
    'async def load_playbook_by_id(self, catalog_id: int, conn=None) -> Optional[Playbook]:'
)
content = content.replace(
    '        async with get_pool_connection() as conn:\n            async with conn.cursor(row_factory=dict_row) as cur:',
    '        if conn is None:\n            async with get_pool_connection() as c:\n                async with c.cursor(row_factory=dict_row) as cur:\n                    await cur.execute("SELECT content FROM noetl.catalog WHERE catalog_id = %s LIMIT 1", (catalog_id,))\n                    row = await cur.fetchone()\n        else:\n            async with conn.cursor(row_factory=dict_row) as cur:\n                await cur.execute("SELECT content FROM noetl.catalog WHERE catalog_id = %s LIMIT 1", (catalog_id,))\n                row = await cur.fetchone()\n        if row:'
)
content = re.sub(
    r'        async with get_pool_connection\(\) as conn:\n            async with conn\.cursor\(row_factory=dict_row\) as cur:\n                await cur\.execute\(\n                    "SELECT content FROM noetl\.catalog WHERE catalog_id = %s LIMIT 1",\n                    \(catalog_id,\)\n                \)\n                row = await cur\.fetchone\(\)\n\n        if row:',
    '',
    content,
    flags=re.DOTALL
)

# Fix load_state_for_update to pass conn
content = content.replace(
    'playbook = await self.playbook_repo.load_playbook_by_id(catalog_id)',
    'playbook = await self.playbook_repo.load_playbook_by_id(catalog_id, conn)'
)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

# 2. Fix events.py (_evaluate_pending_actions)
with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    content = f.read()

content = content.replace(
    '    async def _evaluate_pending_actions(self, state: ExecutionState) -> list[Command]:',
    '    async def _evaluate_pending_actions(self, state: ExecutionState, conn=None) -> list[Command]:'
)
content = content.replace(
    '                async with get_pool_connection() as conn:',
    '                if conn is None:\n                    async with get_pool_connection() as c:\n                        async with c.cursor(row_factory=dict_row) as cur:\n                            await cur.execute("SELECT pending_count FROM noetl.runtime WHERE scope = \'cluster\'")\n                            row = await cur.fetchone()\n                else:\n                    async with conn.cursor(row_factory=dict_row) as cur:\n                        await cur.execute("SELECT pending_count FROM noetl.runtime WHERE scope = \'cluster\'")\n                        row = await cur.fetchone()'
)
content = re.sub(
    r'                async with get_pool_connection\(\) as conn:\n                    async with conn\.cursor\(row_factory=dict_row\) as cur:\n                        await cur\.execute\(\n                            "SELECT COUNT\(\*\) as pending_count FROM noetl\.event WHERE execution_id = %s AND event_type IN \(\'command.issued\', \'loop.item\'\) AND status = \'PENDING\'",\n                            \(int\(state\.execution_id\),\)\n                        \)\n                        row = await cur\.fetchone\(\)',
    '',
    content,
    flags=re.DOTALL
)

# Replace the actual implementation inside _evaluate_pending_actions safely by just rewriting it manually.
with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.write(content)

