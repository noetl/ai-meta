import asyncio
from nats.aio.client import Client as NATS
import json

async def run():
    nc = NATS()
    await nc.connect("nats://noetl:noetl@localhost:32422")
    js = nc.jetstream()
    kv = await js.key_value("noetl_execution_state")
    try:
        keys = await kv.keys()
        print(f"Total keys in noetl_execution_state: {len(keys)}")
        
        # Sample some keys
        for i, k in enumerate(keys[:10]):
            print(f"Key {i}: {k}")
            
    except Exception as e:
        print(f"Error: {e}")
    await nc.close()

asyncio.run(run())
