import asyncio
from noetl.core.cache.nats_kv import get_nats_cache
import json

async def main():
    cache = await get_nats_cache()
    # Find active execution
    import psycopg
    from psycopg.rows import dict_row
    conn = await psycopg.AsyncConnection.connect("postgresql://noetl:noetl@postgres.postgres.svc.cluster.local:5432/noetl")
    async with conn.cursor(row_factory=dict_row) as cur:
        await cur.execute("SELECT execution_id FROM noetl.execution WHERE status = 'RUNNING' ORDER BY created_at DESC LIMIT 1")
        row = await cur.fetchone()
        if not row:
            print("No running execution found")
            return
        execution_id = str(row['execution_id'])
    
    print(f"Checking loop state for execution {execution_id}")
    
    # List loop keys
    if not cache._kv: await cache.connect()
    try:
        keys = await cache._kv.keys(f"exec.{execution_id}.loop.*")
        for key in keys:
            entry = await cache._kv.get(key)
            print(f"{key} -> {json.loads(entry.value.decode())}")
    except Exception as e:
        print(f"Error: {e}")
    await cache.close()

asyncio.run(main())
