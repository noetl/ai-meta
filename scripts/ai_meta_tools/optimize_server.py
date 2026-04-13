import re

def replace_in_file(filepath, pattern, replacement, flags=re.DOTALL):
    with open(filepath, "r") as f:
        content = f.read()
    new_content = re.sub(pattern, replacement, content, flags=flags)
    with open(filepath, "w") as f:
        f.write(new_content)

# 1. Optimize _issue_commands_for_batch in batch.py
batch_file = "noetl/server/api/core/batch.py"

new_issue_commands = """async def _issue_commands_for_batch(job: _BatchAcceptJob, commands: list) -> None:
    from .commands import _build_command_context, _validate_postgres_command_context_or_422, _store_command_context_if_needed
    if not commands: return
    server_url = os.getenv("NOETL_SERVER_URL", "http://noetl.noetl.svc.cluster.local:8082")
    
    # 1. Fetch catalog_id and parent_exec once
    cat_id, p_exec = job.catalog_id, None
    async with get_pool_connection() as conn:
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute("SELECT catalog_id, parent_execution_id FROM noetl.event WHERE execution_id = %s LIMIT 1", (int(job.execution_id),))
            if row := await cur.fetchone():
                cat_id, p_exec = row.get("catalog_id") or cat_id, row.get("parent_execution_id")

            # 2. Prepare command contexts and metadata
            prepared_commands = []
            for cmd in commands:
                cmd_suffix = await _next_snowflake_id(cur)
                cmd_id = f"{cmd.execution_id}:{cmd.step}:{cmd_suffix}"
                new_evt_id = await _next_snowflake_id(cur)
                ctx = _build_command_context(cmd)
                _validate_postgres_command_context_or_422(step=cmd.step, tool_kind=cmd.tool.kind, context=ctx)
                meta = {
                    "command_id": cmd_id, 
                    "step": cmd.step, 
                    "tool_kind": cmd.tool.kind, 
                    "triggered_by": job.last_actionable_event.name if job.last_actionable_event else "batch", 
                    "actionable": True, 
                    "batch_request_id": job.request_id, 
                    **(cmd.metadata or {})
                }
                prepared_commands.append({
                    "cmd_id": cmd_id, "evt_id": new_evt_id, "ctx": ctx, "meta": meta, "step": cmd.step, "execution_id": int(cmd.execution_id), "tool_kind": cmd.tool.kind
                })

            # 3. Parallel context storage (NATS KV calls)
            storage_tasks = [
                _store_command_context_if_needed(execution_id=p["execution_id"], step=p["step"], command_id=p["cmd_id"], context=p["ctx"])
                for p in prepared_commands
            ]
            stored_contexts = await asyncio.gather(*storage_tasks)
            for p, ctx in zip(prepared_commands, stored_contexts):
                p["ctx"] = ctx

            # 4. Batch insert commands
            now = datetime.now(timezone.utc)
            insert_params = [
                (p["evt_id"], p["execution_id"], cat_id, "command.issued", p["step"], p["step"], p["tool_kind"], "PENDING", Json(p["ctx"]), Json(p["meta"]), job.last_actionable_evt_id, p_exec, now)
                for p in prepared_commands
            ]
            await cur.executemany(\"\"\"
                INSERT INTO noetl.event (event_id, execution_id, catalog_id, event_type, node_id, node_name, node_type, status, context, meta, parent_event_id, parent_execution_id, created_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            \"\"\", insert_params)
            await conn.commit()

    # 5. Parallel NATS publish
    publish_items = [(p["execution_id"], p["evt_id"], p["cmd_id"], p["step"]) for p in prepared_commands]
    await _publish_commands_with_recovery(publish_items, server_url=server_url)"""

replace_in_file(batch_file, r'async def _issue_commands_for_batch\(job: _BatchAcceptJob, commands: list\) -> None:.*?await _publish_commands_with_recovery\(.*?\)', new_issue_commands)


# 2. Optimize _publish_commands_with_recovery in recovery.py
recovery_file = "noetl/server/api/core/recovery.py"

new_publish_recovery = """async def _publish_commands_with_recovery(command_events: list[tuple[int, int, str, str]], *, server_url: str) -> None:
    if not command_events: return
    nats_pub = None
    try:
        nats_pub = await get_nats_publisher()
    except Exception as exc:
        logger.warning("[PUBLISH-RECOVERY] NATS publisher unavailable; scheduling delayed recovery: %s", exc)

    async def _safe_publish(exec_id, evt_id, cid, step):
        if nats_pub:
            try:
                await nats_pub.publish_command(execution_id=exec_id, event_id=evt_id, command_id=cid, step=step, server_url=server_url)
            except Exception as exc:
                logger.warning("[PUBLISH-RECOVERY] Initial publish failed for %s: %s", cid, exc)
        
        # Always schedule recovery watchdog
        recovery_task = asyncio.create_task(
            _recover_unclaimed_command_after_delay(
                execution_id=exec_id, event_id=evt_id, command_id=cid,
                step=step, server_url=server_url, delay_seconds=_COMMAND_PUBLISH_RECOVERY_DELAY_SECONDS
            ),
            name=f"command-publish-recovery:{exec_id}:{cid}",
        )
        _track_publish_recovery_task(recovery_task)

    # Parallelize initial publish and recovery task creation
    await asyncio.gather(*[_safe_publish(*args) for args in command_events])"""

replace_in_file(recovery_file, r'async def _publish_commands_with_recovery\(command_events: list\[tuple\[int, int, str, str\]\], \*, server_url: str\) -> None:.*?logger\.warning\("\[PUBLISH-RECOVERY\].*?\)', new_publish_recovery)

