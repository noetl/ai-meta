import asyncio
from nats.aio.client import Client as NATS

async def main():
    nc = NATS()
    await nc.connect("nats://noetl:noetl@nats.nats.svc.cluster.local:4222")
    js = nc.jetstream()
    
    buckets = ["noetl_result_store", "noetl_execution_state", "noetl_loop_result_store"]
    for b in buckets:
        try:
            await js.create_key_value(bucket=b, history=1, ttl=3600*24)
            print(f"Created bucket {b}")
        except Exception as e:
            print(f"Error creating {b}: {e}")
    await nc.close()

asyncio.run(main())
