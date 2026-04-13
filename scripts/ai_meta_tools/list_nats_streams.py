import asyncio
from nats.aio.client import Client as NATS

async def main():
    nc = NATS()
    await nc.connect("nats://noetl:noetl@nats.nats.svc.cluster.local:4222")
    js = nc.jetstream()
    streams = await js.streams_info()
    for s in streams:
        print(f"Stream: {s.config.name} | Messages: {s.state.messages}")
    await nc.close()

asyncio.run(main())
