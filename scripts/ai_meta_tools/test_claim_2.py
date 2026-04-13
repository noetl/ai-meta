import asyncio
import json
from noetl.core.cache.nats_kv import get_nats_cache

async def main():
    cache = await get_nats_cache()
    
    state = await cache.get_loop_state("601068894589026338", "fetch_assessments", event_id="loop_601069462950772950_1775720264958348638")
    print(f"State Before: {json.dumps(state, indent=2)}")

import logging
logging.basicConfig(level=logging.INFO)
asyncio.run(main())
