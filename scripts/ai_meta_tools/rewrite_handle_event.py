import re

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    content = f.read()

# I will replace the start of handle_event up to `state = await self.state_store.load_state(event.execution_id)`
start_pattern = r'    async def handle_event\(.*?already_persisted: bool = False\) -> list\[Command\]:.*?state = await self.state_store.load_state\(event.execution_id\)'
replacement = """    async def handle_event(self, event: Event, already_persisted: bool = False) -> list[Command]:
        logger.debug(
            "[ENGINE] handle_event called: event.name=%s, step=%s, execution=%s",
            event.name, event.step, event.execution_id
        )

        async with get_pool_connection() as conn:
            # We use Postgres advisory lock instead of row lock to avoid Deadlocks 
            # if we insert events in the same transaction
            async with conn.cursor() as cur:
                await cur.execute("SELECT pg_advisory_xact_lock(%s)", (int(event.execution_id),))
                state = await self.state_store.load_state_for_update(str(event.execution_id), conn)
                """

content = re.sub(start_pattern, replacement, content, flags=re.DOTALL)

# Let's fix the end
content = re.sub(
    r'\s*# Cache and return.*?return commands',
    '\n                await self.state_store.save_state(state, conn)\n                return commands',
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.write(content)

