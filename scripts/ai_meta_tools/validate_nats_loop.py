import asyncio
import sys
import json
from nats.aio.client import Client as NATS
import os

async def main():
    nc = NATS()
    try:
        await nc.connect("nats://localhost:30422")
        js = nc.jetstream()
        kv = await js.key_value("noetl_state")
        key = "execution:601594998663938806:loop:fetch_assessments:loop_601595090955404187_1775782923455094709"
        try:
            entry = await kv.get(key)
            print(f"Key: {key}")
            print(f"Value: {entry.value.decode('utf-8')}")
        except Exception as e:
            print(f"Key {key} not found: {e}")
            
    finally:
        await nc.close()

if __name__ == '__main__':
    asyncio.run(main())
