import asyncio
from nats.aio.client import Client as NATS
from nats.js.kv import KeyValue

async def main():
    nc = NATS()
    await nc.connect("nats://noetl:noetl@nats.nats.svc.cluster.local:4222")
    js = nc.jetstream()
    
    buckets = ["noetl_result_store", "noetl_execution_state", "noetl_loop_result_store"]
    for b in buckets:
        try:
            kv = await js.key_value(b)
            print(f"Purging bucket {b}...")
            # We can't easily purge by key prefix without listing everything.
            # For a demo/dev environment, we'll just purge the whole bucket's stream if it's too full.
            # But here I'll just try to delete keys for known old executions.
            # Actually, let's just delete the buckets and they will be recreated.
            await js.delete_key_value(b)
            print(f"Deleted bucket {b}")
        except Exception as e:
            print(f"Error purging {b}: {e}")
    await nc.close()

asyncio.run(main())
