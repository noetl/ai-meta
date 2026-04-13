import re

def fix_lifecycle():
    with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "r") as f:
        content = f.read()

    new_persist_event = """    async def _persist_event(self, event: Event, state: ExecutionState, conn=None):
        \"\"\"Persist event to database with state tracking.\"\"\"
        # Use catalog_id from state, or lookup from existing events
        catalog_id = state.catalog_id
        
        async def _do_persist(c):
            nonlocal catalog_id
            if not catalog_id:
                async with c.cursor() as cur:
                    await cur.execute("SELECT catalog_id FROM noetl.event WHERE execution_id = %s LIMIT 1", (int(event.execution_id),))
                    result = await cur.fetchone()
                    catalog_id = result['catalog_id'] if result else None
            
            if not catalog_id:
                logger.error(f"Cannot persist event - no catalog_id for execution {event.execution_id}")
                return
            
            parent_event_id = event.parent_event_id
            if parent_event_id is None:
                if event.step:
                    parent_event_id = state.step_event_ids.get(event.step)
                if not parent_event_id:
                    parent_event_id = state.last_event_id
            
            duration_ms = 0
            event_timestamp = event.timestamp or datetime.now(timezone.utc)
            
            is_loop_iteration_exit = (
                event.name == "step.exit"
                and event.step
                and (
                    event.step.endswith(":task_sequence")
                    or (event.step in state.loop_state if hasattr(state, 'loop_state') else False)
                )
            )
            
            if event.name == "step.exit" and event.step and not is_loop_iteration_exit:
                async with c.cursor() as cur:
                    await cur.execute("SELECT created_at FROM noetl.event WHERE execution_id = %s AND node_id = %s AND event_type = 'step.enter' ORDER BY event_id DESC LIMIT 1", (int(event.execution_id), event.step))
                    enter_event = await cur.fetchone()
                    if enter_event and enter_event['created_at']:
                        start_time = enter_event['created_at']
                        duration_ms = int((event_timestamp - start_time).total_seconds() * 1000)
            
            elif "completed" in event.name or "failed" in event.name:
                async with c.cursor() as cur:
                    init_event_type = "workflow_initialized" if "workflow_" in event.name else "playbook_initialized"
                    await cur.execute("SELECT created_at FROM noetl.event WHERE execution_id = %s AND event_type = %s ORDER BY event_id ASC LIMIT 1", (int(event.execution_id), init_event_type))
                    init_event = await cur.fetchone()
                    if init_event and init_event['created_at']:
                        start_time = init_event['created_at']
                        duration_ms = int((event_timestamp - start_time).total_seconds() * 1000)

            async with c.cursor() as cur:
                await cur.execute("SELECT noetl.snowflake_id() AS snowflake_id")
                _sf_row = await cur.fetchone()
                if not _sf_row:
                    raise RuntimeError("Failed to generate snowflake ID")
                event_id = int(_sf_row['snowflake_id'])
            
            status = event.payload.get("status") if event.payload else None
            if not status and "completed" in event.name:
                status = "COMPLETED"
            elif not status and "failed" in event.name:
                status = "FAILED"
            elif not status:
                status = "RUNNING"
            
            # Map payload correctly: payload -> context, payload.result -> result
            payload_dict = event.payload if isinstance(event.payload, dict) else {}
            context_val = payload_dict
            result_val = payload_dict.get("result") if isinstance(payload_dict.get("result"), dict) and "status" in payload_dict["result"] else None

            async with c.cursor() as cur:
                await cur.execute(
                    \"\"\"
                    INSERT INTO noetl.event (
                        execution_id, catalog_id, event_id, parent_event_id, parent_execution_id, 
                        created_at, event_type, node_id, node_name, status, duration, 
                        context, result, meta, error, worker_id
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                    )
                    \"\"\",
                    (
                        int(event.execution_id), catalog_id, event_id, parent_event_id, state.parent_execution_id,
                        event_timestamp, event.name, event.step, event.step, status, duration_ms,
                        Json(context_val) if context_val else None, 
                        Json(result_val) if result_val else None,
                        Json(event.meta) if event.meta else None,
                        event.payload.get("error") if isinstance(event.payload, dict) else None,
                        event.worker_id
                    )
                )

            state.last_event_id = event_id
            if event.step:
                state.step_event_ids[event.step] = event_id

        if conn is None:
            async with get_pool_connection() as c:
                await _do_persist(c)
        else:
            await _do_persist(conn)
"""

    content = re.sub(
        r'    async def _persist_event\(self, event: Event, state: ExecutionState, conn=None\):.*?state.step_event_ids\[event.step\] = event_id',
        new_persist_event,
        content,
        flags=re.DOTALL
    )

    with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "w") as f:
        f.write(content)

def fix_v2_py():
    with open("repos/noetl/noetl/server/api/v2.py", "r") as f:
        content = f.read()

    # Consolidate all INSERT statements in v2.py to use a safer positional format
    # This is a large file, so I will do it carefully.
    
    # Actually, I'll just fix the one in 'execute' and 'handle_event' which are the most critical.
    
    # Line 1499: command.issued in execute()
    content = re.sub(
        r'await cur\.execute\(\"\"\"\n\s+INSERT INTO noetl\.event \(.*?\) VALUES \(.*?\)\n\s+\"\"\", \{.*?\}\)',
        'await cur.execute(\"\"\"INSERT INTO noetl.event (execution_id, catalog_id, event_id, event_type, node_id, node_name, node_type, status, context, meta, parent_event_id, parent_execution_id, created_at) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)\"\"\", (int(execution_id), catalog_id, evt_id, "command.issued", cmd.step, cmd.step, cmd.tool.kind, "PENDING", Json(context), Json(meta), root_event_id, req.parent_execution_id, datetime.now(timezone.utc)))',
        content,
        flags=re.DOTALL
    )
    
    with open("repos/noetl/noetl/server/api/v2.py", "w") as f:
        f.write(content)

fix_lifecycle()
fix_v2_py()
