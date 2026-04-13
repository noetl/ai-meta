import re

# Fix recovery.py
with open("noetl/server/api/core/recovery.py", "r") as f:
    content = f.read()
content = content.replace('await asyncio.gather(*[_safe_publish(*args) for args in command_events]): %s",', 'await asyncio.gather(*[_safe_publish(*args) for args in command_events])')
with open("noetl/server/api/core/recovery.py", "w") as f:
    f.write(content)

# Fix nats_worker.py
with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

# Look for the syntax error around line 198
lines = content.split('\n')
for i, line in enumerate(lines):
    if "initial_limit=max(1.0, self._max_inflight_commands / 2.0)" in line:
        if i + 1 < len(lines) and not lines[i].strip().endswith(','):
             # It likely missing a comma at the end of the line if it's in a constructor
             lines[i] = lines[i].replace('2.0)', '2.0),')

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write('\n'.join(lines))
