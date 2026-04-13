import re

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    content = f.read()

# Add conn to handle_event signature
content = content.replace(
    'async def handle_event(self, event: Event, already_persisted: bool = False) -> list[Command]:',
    'async def handle_event(self, event: Event, conn=None, already_persisted: bool = False) -> list[Command]:'
)

# Replace load_state with load_state_for_update
# Look for: cached_state = self.state_store.get_state(event.execution_id)
# This was removed. The new logic is:
# state = await self.state_store.load_state(event.execution_id)

content = re.sub(
    r'        state = await self\.state_store\.load_state\(event\.execution_id\)\n        if not state:',
    '        if conn:\n            state = await self.state_store.load_state_for_update(event.execution_id, conn)\n        else:\n            state = await self.state_store.load_state(event.execution_id)\n        if not state:',
    content,
    flags=re.DOTALL
)

# And replace save_state(state) with save_state(state, conn)
# There are multiple occurrences of save_state!
content = content.replace('await self.state_store.save_state(state)', 'await self.state_store.save_state(state, conn)')

# We also need to fix _persist_event to use conn if provided, but actually _persist_event opens its own conn
# and doesn't block state save, so it's fine.

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.write(content)

