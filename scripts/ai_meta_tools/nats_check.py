import sys
import asyncio
from nats.aio.client import Client as NATS
async def main():
    nc = NATS()
    await nc.connect("nats://nats.nats.svc.cluster.local:4222")
    js = nc.jetstream()
    kv = await js.key_value("execution_cache")
    entry = await kv.get("601068894589026338:loop:fetch_assessments:loop_601069462950772950_1775720264958348638")
    print(entry.value.decode("utf-8"))
    await nc.close()
asyncio.run(main())
