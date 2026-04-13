import re

with open("noetl/core/dsl/engine/engine/commands.py", "r") as f:
    lines = f.read().split('\n')

# Find the redundant block and remove it
start_line = -1
end_line = -1
for i, line in enumerate(lines):
    if "if loop_event_id:" in line and "await nats_cache.save_loop_collection" in lines[i+1]:
        # This is the end of my new block
        if lines[i+2].strip() == "else:":
            # The next else is the redundant one
            start_line = i + 2
            # Find the end of this block
            for j in range(start_line + 1, len(lines)):
                if "setattr(state, ephemeral_key, collection)" in lines[j]:
                    end_line = j + 1
                    break
            break

if start_line != -1 and end_line != -1:
    del lines[start_line:end_line]

with open("noetl/core/dsl/engine/engine/commands.py", "w") as f:
    f.write('\n'.join(lines))
