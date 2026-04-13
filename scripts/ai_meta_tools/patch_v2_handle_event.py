import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

# Replace where engine.handle_event is called for normal events (line ~2210)
# skip_engine_events ...
# commands = []
# if req.name not in skip_engine_events:
#     commands = await engine.handle_event(event, already_persisted=True)

replacement = """        if req.name not in skip_engine_events:
            # We wrap engine handling in a transaction and advisory lock to serialize parallel events
            async with get_pool_connection() as engine_conn:
                async with engine_conn.transaction():
                    async with engine_conn.cursor() as cur:
                        await cur.execute("SELECT pg_advisory_xact_lock(%s)", (int(req.execution_id),))
                    commands = await engine.handle_event(event, conn=engine_conn, already_persisted=True)
            commands_generated = bool(commands)
            logger.debug(f"[ENGINE] Processed {req.name} for step {req.step}, generated {len(commands)} commands")
"""

content = re.sub(
    r'        if req.name not in skip_engine_events:\n            # Pass already_persisted.*?\n            commands = await engine.handle_event\(event, already_persisted=True\)\n            commands_generated = bool\(commands\)\n            logger.debug\(f"\[ENGINE\] Processed {req.name}.*?"\)',
    replacement,
    content,
    flags=re.DOTALL
)

# Replace the other place in batch job processor:
# commands = await engine.handle_event(job.last_actionable_event, already_persisted=True)

replacement_job = """        async with get_pool_connection() as engine_conn:
            async with engine_conn.transaction():
                async with engine_conn.cursor() as cur:
                    await cur.execute("SELECT pg_advisory_xact_lock(%s)", (int(job.last_actionable_event.execution_id),))
                commands = await engine.handle_event(job.last_actionable_event, conn=engine_conn, already_persisted=True)
"""

content = re.sub(
    r'        commands = await engine\.handle_event\(job\.last_actionable_event, already_persisted=True\)',
    replacement_job,
    content
)

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)

