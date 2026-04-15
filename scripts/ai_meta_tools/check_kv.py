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
        for k in keys:
            if "loop:fetch_medications" in k:
                entry = await kv.get(k)
                print(f"{k}: {entry.value.decode('utf-8')}")
    except Exception as e:
        print(f"Error: {e}")
    await nc.close()

asyncio.run(run())
