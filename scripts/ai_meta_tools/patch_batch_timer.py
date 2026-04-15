import re

with open("repos/noetl/noetl/server/api/core/batch.py", "r") as f:
    text = f.read()

replacement = """async def _process_accepted_batch(job: _BatchAcceptJob) -> int:
    import time
    import logging
    log = logging.getLogger(__name__)
    
    from .events import _invalidate_execution_state_cache
    commands = []
    engine = None
    t0 = time.perf_counter()
    if job.last_actionable_event:
        engine = get_engine()
        async with get_pool_connection() as engine_conn:
            async with engine_conn.transaction():
                async with engine_conn.cursor() as cur:
                    await cur.execute(f"SET LOCAL statement_timeout = {int(_BATCH_PROCESSING_STATEMENT_TIMEOUT_MS)}")
                    await cur.execute("SELECT pg_advisory_xact_lock(%s)", (int(job.last_actionable_event.execution_id),))
                    t1 = time.perf_counter()
                    commands = await engine.handle_event(job.last_actionable_event, conn=engine_conn, already_persisted=True)
                    t2 = time.perf_counter()
                    log.info(f"[PERF] engine.handle_event took {t2 - t1:.3f}s for event {job.last_actionable_event.name}")
    try: 
        t3 = time.perf_counter()
        await _issue_commands_for_batch(job, commands)
        t4 = time.perf_counter()
        log.info(f"[PERF] _issue_commands_for_batch took {t4 - t3:.3f}s for {len(commands)} commands")
    except Exception as e:
        if engine and commands: await _invalidate_execution_state_cache(str(job.execution_id), reason=f"batch_command_issue_failed:{type(e).__name__}", engine=engine)
        raise
    return len(commands)"""

text = re.sub(r'async def _process_accepted_batch\(job: _BatchAcceptJob\) -> int:.*?return len\(commands\)', replacement, text, flags=re.DOTALL)

with open("repos/noetl/noetl/server/api/core/batch.py", "w") as f:
    f.write(text)

