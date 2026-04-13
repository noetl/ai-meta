import re

with open("noetl/server/api/core/batch.py", "r") as f:
    content = f.read()

# Replace the sequential loop with a batch insert using executemany
old_loop = """            for item in req.events:
                _validate_reference_only_payload(item.payload)
                evt_id = await _next_snowflake_id(cur); event_ids.append(evt_id)
                meta = {"actionable": item.actionable, "informative": item.informative, "batch_request_id": request_id, "persisted_event_id": str(evt_id), "worker_id": req.worker_id, "idempotency_key": idempotency_key}
                if cmd_id := _extract_command_id_from_payload(item.payload): meta["command_id"] = cmd_id
                await cur.execute(\"\"\"
                    INSERT INTO noetl.event (event_id, execution_id, catalog_id, event_type, node_id, node_name, status, result, meta, worker_id, error, created_at)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                \"\"\", (evt_id, exec_id, catalog_id, item.name, item.step, item.step, _status_from_event_name(item.name), Json(_build_reference_only_result(payload=item.payload, status=_status_from_event_name(item.name))), Json(meta), req.worker_id, _extract_event_error(item.payload), datetime.now(timezone.utc)))
                if cmd_id and item.name in _COMMAND_TERMINAL_EVENT_TYPES: term_cmd_ids.add(cmd_id)
                if item.actionable and item.name not in skip_engine:
                    last_act_evt = Event(execution_id=req.execution_id, step=item.step, name=item.name, payload=item.payload, meta=meta, timestamp=datetime.now(timezone.utc), worker_id=req.worker_id)
                    last_act_evt_id = evt_id"""

new_loop = """            now = datetime.now(timezone.utc)
            insert_params = []
            for item in req.events:
                _validate_reference_only_payload(item.payload)
                evt_id = await _next_snowflake_id(cur); event_ids.append(evt_id)
                meta = {"actionable": item.actionable, "informative": item.informative, "batch_request_id": request_id, "persisted_event_id": str(evt_id), "worker_id": req.worker_id, "idempotency_key": idempotency_key}
                if cmd_id := _extract_command_id_from_payload(item.payload): meta["command_id"] = cmd_id
                
                insert_params.append((
                    evt_id, exec_id, catalog_id, item.name, item.step, item.step, 
                    _status_from_event_name(item.name), 
                    Json(_build_reference_only_result(payload=item.payload, status=_status_from_event_name(item.name))), 
                    Json(meta), req.worker_id, _extract_event_error(item.payload), now
                ))

                if cmd_id and item.name in _COMMAND_TERMINAL_EVENT_TYPES: term_cmd_ids.add(cmd_id)
                if item.actionable and item.name not in skip_engine:
                    last_act_evt = Event(execution_id=req.execution_id, step=item.step, name=item.name, payload=item.payload, meta=meta, timestamp=now, worker_id=req.worker_id)
                    last_act_evt_id = evt_id
            
            if insert_params:
                await cur.executemany(\"\"\"
                    INSERT INTO noetl.event (event_id, execution_id, catalog_id, event_type, node_id, node_name, status, result, meta, worker_id, error, created_at)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                \"\"\", insert_params)"""

content = content.replace(old_loop, new_loop)

with open("noetl/server/api/core/batch.py", "w") as f:
    f.write(content)
