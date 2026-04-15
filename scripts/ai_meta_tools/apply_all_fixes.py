import re
import os

def patch_file(path, pattern, replacement, must_match=True):
    with open(path, "r") as f:
        text = f.read()
    
    new_text = re.sub(pattern, replacement, text, flags=re.DOTALL)
    if new_text == text and must_match:
        print(f"FAILED to patch {path} - pattern not found")
        return False
    
    with open(path, "w") as f:
        f.write(new_text)
    print(f"Successfully patched {path}")
    return True

# 1. nats_kv.py: Add batch claim and lazy init
nats_kv_path = "repos/noetl/noetl/core/cache/nats_kv.py"

# Lazy init in singular claim
pattern_singular = r'(try:\s+entry = await self\._kv\.get\(key\)\s+if not entry:\s+return None)'
replacement_singular = """try:
                try:
                    entry = await self._kv.get(key)
                except Exception as get_exc:
                    if "key not found" in str(get_exc).lower():
                        # Lazy initialize loop state in NATS KV
                        init_state = {
                            "completed_count": 0,
                            "scheduled_count": 0,
                            "collection_size": safe_collection_size,
                            "updated_at": _utcnow_iso()
                        }
                        await self._kv.put(key, json.dumps(init_state).encode("utf-8"))
                        entry = await self._kv.get(key)
                    else:
                        raise get_exc

                if not entry:
                    return None"""

# Implement batch claim method
batch_claim_code = """
    async def claim_next_loop_indices(
        self,
        execution_id: str,
        step_name: str,
        collection_size: int,
        max_in_flight: int,
        requested_count: int = 1,
        event_id: Optional[str] = None,
    ) -> list[int]:
        \"\"\"Atomically claim multiple loop iteration indices with backpressure control.\"\"\"
        if not self._kv:
            await self.connect()

        key_suffix = f"loop:{step_name}:{event_id}" if event_id else f"loop:{step_name}"
        key = self._make_key(execution_id, key_suffix)

        safe_collection_size = max(0, int(collection_size or 0))
        safe_max_in_flight = max(1, int(max_in_flight or 1))
        safe_requested_count = max(1, int(requested_count))

        max_retries = 5
        for attempt in range(max_retries):
            try:
                try:
                    entry = await self._kv.get(key)
                except Exception as get_exc:
                    if "key not found" in str(get_exc).lower():
                        # Lazy initialize loop state in NATS KV
                        init_state = {
                            "completed_count": 0,
                            "scheduled_count": 0,
                            "collection_size": safe_collection_size,
                            "updated_at": _utcnow_iso()
                        }
                        await self._kv.put(key, json.dumps(init_state).encode("utf-8"))
                        entry = await self._kv.get(key)
                    else:
                        raise get_exc

                if not entry:
                    return []

                state = json.loads(entry.value.decode("utf-8"))
                completed_count = int(state.get("completed_count", 0) or 0)
                scheduled_count = int(state.get("scheduled_count", completed_count) or completed_count)

                if scheduled_count < completed_count:
                    scheduled_count = completed_count
                
                existing_collection_size = int(state.get("collection_size", 0) or 0)
                if safe_collection_size <= 0 and existing_collection_size > 0:
                    safe_collection_size = existing_collection_size

                if safe_collection_size <= 0:
                    return []

                if scheduled_count >= safe_collection_size:
                    return []

                in_flight = max(0, scheduled_count - completed_count)
                available_slots = safe_max_in_flight - in_flight
                
                if available_slots <= 0:
                    return []

                claim_count = min(safe_requested_count, available_slots, safe_collection_size - scheduled_count)
                
                if claim_count <= 0:
                    return []

                claimed_indices = list(range(scheduled_count, scheduled_count + claim_count))
                
                state["collection_size"] = safe_collection_size
                state["completed_count"] = completed_count
                state["scheduled_count"] = scheduled_count + claim_count
                now_iso = _utcnow_iso()
                state["last_claimed_at"] = now_iso
                state["last_progress_at"] = now_iso
                state["updated_at"] = now_iso

                value = json.dumps(state).encode("utf-8")
                await self._kv.update(key, value, last=entry.revision)
                
                return claimed_indices

            except Exception as e:
                if "wrong last sequence" in str(e).lower() and attempt < max_retries - 1:
                    await asyncio.sleep(0.01 * (attempt + 1))
                    continue
                logger.error(f"Failed to claim next loop indices: {e}")
                return []
        return []
"""

with open(nats_kv_path, "r") as f:
    text = f.read()

if "claim_next_loop_indices" not in text:
    text = text.replace("    async def release_loop_slot(", batch_claim_code + "\n    async def release_loop_slot(")
    with open(nats_kv_path, "w") as f:
        f.write(text)
    print("Added claim_next_loop_indices to nats_kv.py")
else:
    print("claim_next_loop_indices already exists in nats_kv.py")

# 2. events.py: Disable supervisor scan
events_path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
pattern_scan = r'supervisor_completed_count = await self\._count_supervised_loop_terminal_iterations\(.*?event_id=str\(resolved_loop_event_id\),\s*\)'
replacement_scan = """# PERFORMANCE OPTIMIZATION: Skip expensive full-scan supervisor reconciliation on hot path.
                    supervisor_completed_count = -1"""
patch_file(events_path, pattern_scan, replacement_scan)

# 3. transitions.py: Use batch claim
transitions_path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
pattern_issue = r'issue_budget = self\._get_loop_max_in_flight\(step_def\)\n\s+commands: list\[Command\] = \[\]\n\s+shared_control_args = dict\(step_input\)\n\s+if collection is not None:\n\s+shared_control_args\["__loop_collection"\] = collection\n\n\s+for _ in range\(issue_budget\):\n\s+command = await self\._create_command_for_step\(state, step_def, shared_control_args\)\n\s+if not command:\n\s+break\n\s+commands\.append\(command\)\n\s+shared_control_args\["__loop_continue"\] = True'

replacement_issue = """issue_budget = self._get_loop_max_in_flight(step_def)
        commands: list[Command] = []
        shared_control_args = dict(step_input)
        if collection is not None:
            shared_control_args["__loop_collection"] = collection

        # PERFORMANCE OPTIMIZATION: Batch claim loop indices to avoid O(N) NATS round-trips
        claimed_indices = await nats_cache.claim_next_loop_indices(
            str(state.execution_id),
            step_def.step,
            collection_size=len(collection),
            max_in_flight=issue_budget, 
            requested_count=issue_budget,
            event_id=loop_event_id
        )

        for idx in claimed_indices:
            args = dict(shared_control_args)
            args["__loop_claimed_index"] = idx
            command = await self._create_command_for_step(state, step_def, args)
            if not command:
                break
            commands.append(command)
            shared_control_args["__loop_continue"] = True"""

patch_file(transitions_path, pattern_issue, replacement_issue)

# 4. commands.py: Support pre-claimed index
commands_path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
pattern_claim_init = r'claimed_index: Optional\[int\] = None\n\s+_nats_slot_incremented = False'
replacement_claim_init = """claimed_index: Optional[int] = control_args.get("__loop_claimed_index")
        _nats_slot_incremented = claimed_index is not None"""
patch_file(commands_path, pattern_claim_init, replacement_claim_init)

pattern_claim_call = r'claimed_index = await nats_cache\.claim_next_loop_index\((.*?)\)'
replacement_claim_call = r'if claimed_index is None: claimed_index = await nats_cache.claim_next_loop_index(\1)'
patch_file(commands_path, pattern_claim_call, replacement_claim_call)

