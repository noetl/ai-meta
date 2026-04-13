import re

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "r") as f:
    content = f.read()

# Replace the beginning of handle_event to use transaction and load_state_for_update
replacement = """
    async def handle_event(self, event: Event, already_persisted: bool = False) -> list[Command]:
        logger.debug(
            "[ENGINE] handle_event called: event.name=%s, step=%s, execution=%s, already_persisted=%s",
            event.name,
            event.step,
            event.execution_id,
            already_persisted,
        )

        async with get_pool_connection() as conn:
            async with conn.transaction():
                # Load state FOR UPDATE to serialize all parallel events for this execution
                state = await self.state_store.load_state_for_update(event.execution_id, conn)
                if not state:
                    logger.error(f"Execution state not found: {event.execution_id}")
                    return []
                
                commands = []

                # Ensure payload is dictionary
"""

content = re.sub(
    r'    async def handle_event\(.*?already_persisted=False\) -> list\[Command\]:.*?commands = \[\]\s+# Ensure payload is dictionary',
    replacement,
    content,
    flags=re.DOTALL
)

# And at the end of handle_event, replace the cache setting
end_replacement = """
                # Cache state (actually saves to PG with conn)
                await self.state_store.save_state(state, conn)
                return commands
"""

content = re.sub(
    r'\s+# Cache state.*?return commands',
    end_replacement,
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/events.py", "w") as f:
    f.write(content)

