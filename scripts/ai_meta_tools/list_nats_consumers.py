import asyncio
from nats.aio.client import Client as NATS

async def main():
    nc = NATS()
    await nc.connect("nats://noetl:noetl@nats.nats.svc.cluster.local:4222")
    js = nc.jetstream()
    try:
        consumers = await js.consumers_info("NOETL_COMMANDS")
        for c in consumers:
            print(f"Consumer: {c.name} | Unprocessed: {c.num_pending}")
    except Exception as e:
        print(f"Error: {e}")
    await nc.close()

asyncio.run(main())
