import asyncio
from nats.aio.client import Client as NATS
import json

async def run():
    nc = NATS()
    await nc.connect("nats://noetl:noetl@localhost:32422")
    js = nc.jetstream()
    kv = await js.key_value("noetl_execution_state")
    
    execution_id = "605206939399618925"
    
    keys = await kv.keys()
    
    for k in keys:
        if execution_id in k and "loop:fetch_assessments" in k:
            entry = await kv.get(k)
            state = json.loads(entry.value.decode("utf-8"))
            print(f"Key: {k}")
            print(f"  completed_count: {state.get('completed_count')}")
            print(f"  scheduled_count: {state.get('scheduled_count')}")
            print(f"  collection_size: {state.get('collection_size')}")

    await nc.close()

asyncio.run(run())
