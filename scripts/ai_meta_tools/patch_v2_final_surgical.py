import re

with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
    content = f.read()

# 1. Fix get_execution_status
content = content.replace(
    'state = engine.state_store.get_state(execution_id)',
    'state = await engine.state_store.load_state(execution_id)'
)

# 2. Fix handle_event transaction wrap and advisory lock
# Find: if req.name not in skip_engine_events:
#        commands = await engine.handle_event(event, already_persisted=True)

pattern = r'(if req\.name not in skip_engine_events:)\n\s+commands = await engine\.handle_event\(event, already_persisted=True\)'
replacement = r'\1\n            async with get_pool_connection() as engine_conn:\n                async with engine_conn.transaction():\n                    async with engine_conn.cursor() as cur:\n                        await cur.execute("SELECT pg_advisory_xact_lock(%s)", (int(req.execution_id),))\n                    commands = await engine.handle_event(event, conn=engine_conn, already_persisted=True)'
content = re.sub(pattern, replacement, content)

# 3. Fix handle_event job processing transaction wrap
pattern_job = r'(commands = await engine\.handle_event\(job\.last_actionable_event, already_persisted=True\))'
replacement_job = r'async with get_pool_connection() as engine_conn:\n            async with engine_conn.transaction():\n                async with engine_conn.cursor() as cur:\n                    await cur.execute("SELECT pg_advisory_xact_lock(%s)", (int(job.last_actionable_event.execution_id),))\n                commands = await engine.handle_event(job.last_actionable_event, conn=engine_conn, already_persisted=True)'
content = content.replace(pattern_job, replacement_job)

with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
    f.write(content)

