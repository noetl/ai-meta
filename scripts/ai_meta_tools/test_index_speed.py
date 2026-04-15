import asyncio
import asyncpg
import time

async def test():
    conn = await asyncpg.connect("postgresql://demo:demo@localhost:54321/noetl")
    
    query = """
    SELECT COUNT(DISTINCT idx.loop_iteration_index) AS cnt
    FROM (
        SELECT NULLIF(meta->>'loop_iteration_index', '')::int AS loop_iteration_index
        FROM noetl.event
        WHERE execution_id = 605206939399618925
          AND node_name = 'fetch_assessments:task_sequence'
          AND event_type = 'call.done'
          AND COALESCE(meta->>'loop_event_id', meta->>'__loop_epoch_id') = 'loop_605209871176172480_1776213846536277180'
    ) idx
    WHERE idx.loop_iteration_index IS NOT NULL
    """
    
    t0 = time.perf_counter()
    count = await conn.fetchval(query)
    t1 = time.perf_counter()
    print(f"Query returned {count} in {(t1-t0)*1000:.1f}ms")
    await conn.close()

asyncio.run(test())
