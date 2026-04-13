import asyncio
from psycopg.rows import dict_row
from noetl.core.db.pool import get_pool_connection

async def add_state_column():
    async with get_pool_connection() as conn:
        async with conn.cursor() as cur:
            await cur.execute("ALTER TABLE noetl.execution ADD COLUMN IF NOT EXISTS state JSONB;")

asyncio.run(add_state_column())
