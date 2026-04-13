import asyncio
from noetl.core.cache.nats_kv import get_nats_cache
async def main():
    cache = await get_nats_cache()
    # Find execution ID
    import psycopg
    from psycopg.rows import dict_row
    conn = await psycopg.AsyncConnection.connect(
        "postgresql://noetl:noetl@postgres.postgres.svc.cluster.local:5432/noetl"
    )
    async with conn.cursor(row_factory=dict_row) as cur:
        await cur.execute("SELECT execution_id FROM noetl.execution ORDER BY created_at DESC LIMIT 1")
        row = await cur.fetchone()
        if not row:
            print("No execution found")
            return
        execution_id = str(row['execution_id'])
    
    print(f"Checking execution {execution_id}")
    
    # We need the event_id for the loop
    # Let's just list keys for this execution
    if not cache._kv:
        await cache.connect()
    
    keys = await cache._kv.keys(f"{execution_id}:loop:*")
    for key in keys:
        entry = await cache._kv.get(key)
        import json
        print(f"{key} -> {json.loads(entry.value)}")

asyncio.run(main())
