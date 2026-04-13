import re
import json

with open("noetl/core/cache/nats_kv.py", "r") as f:
    lines = f.readlines()

# Find the end of _make_key
end_index = -1
for i, line in enumerate(lines):
    if "return f\\\"exec.{safe_exec_id}.{safe_key_type}\\\"" in line:
        end_index = i + 1
        break

if end_index != -1:
    methods = [
        "\\n",
        "    async def get_loop_collection(self, execution_id: str, step_name: str, loop_event_id: str) -> Optional[list]:\\n",
        "        \\\"\\\"\\\"Retrieve rendered loop collection from NATS KV.\\\"\\\"\\\"\\n",
        "        if not self._kv: await self.connect()\\n",
        "        key = f\\\"loop_coll:{execution_id}:{step_name}:{loop_event_id}\\\"\\n",
        "        try:\\n",
        "            entry = await self._kv.get(key)\\n",
        "            if entry:\\n",
        "                return json.loads(entry.value.decode())\\n",
        "        except Exception:\\n",
        "            pass\\n",
        "        return None\\n",
        "\\n",
        "    async def save_loop_collection(self, execution_id: str, step_name: str, loop_event_id: str, collection: list):\\n",
        "        \\\"\\\"\\\"Save rendered loop collection to NATS KV.\\\"\\\"\\\"\\n",
        "        if not self._kv: await self.connect()\\n",
        "        key = f\\\"loop_coll:{execution_id}:{step_name}:{loop_event_id}\\\"\\n",
        "        try:\\n",
        "            data = json.dumps(collection).encode()\\n",
        "            await self._kv.put(key, data)\\n",
        "            logger.debug(f\\\"[NATS-KV] Saved loop collection for {step_name} (size={len(data)} bytes)\\\")\\n",
        "        except Exception as e:\\n",
        "            logger.warning(f\\\"[NATS-KV] Failed to save loop collection: {e}\\\")\\n"
    ]
    # Corrected the escaping for python write
    methods = [
        "\n",
        "    async def get_loop_collection(self, execution_id: str, step_name: str, loop_event_id: str) -> Optional[list]:\n",
        "        \"\"\"Retrieve rendered loop collection from NATS KV.\"\"\"\n",
        "        if not self._kv: await self.connect()\n",
        "        key = f\"loop_coll:{execution_id}:{step_name}:{loop_event_id}\"\n",
        "        try:\n",
        "            entry = await self._kv.get(key)\n",
        "            if entry:\n",
        "                return json.loads(entry.value.decode())\n",
        "        except Exception:\n",
        "            pass\n",
        "        return None\n",
        "\n",
        "    async def save_loop_collection(self, execution_id: str, step_name: str, loop_event_id: str, collection: list):\n",
        "        \"\"\"Save rendered loop collection to NATS KV.\"\"\"\n",
        "        if not self._kv: await self.connect()\n",
        "        key = f\"loop_coll:{execution_id}:{step_name}:{loop_event_id}\"\n",
        "        try:\n",
        "            data = json.dumps(collection).encode()\n",
        "            await self._kv.put(key, data)\n",
        "            logger.debug(f\"[NATS-KV] Saved loop collection for {step_name} (size={len(data)} bytes)\")\n",
        "        except Exception as e:\n",
        "            logger.warning(f\"[NATS-KV] Failed to save loop collection: {e}\")\n"
    ]
    for m in reversed(methods):
        lines.insert(end_index, m)

with open("noetl/core/cache/nats_kv.py", "w") as f:
    f.writelines(lines)
