import asyncio
from noetl.core.dsl.v2.engine import StateStore
import logging

class DummyStateStore(StateStore):
    async def load_state(self, execution_id: int):
        pass

print("OK")
