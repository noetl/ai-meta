import os
import re

def fix_execution_ids_v2(dir_path):
    counter = 99500
    id_map = {}

    def get_id(old_id):
        nonlocal counter
        if old_id not in id_map:
            # If it's already a numeric string, keep it unless we want to normalize everything
            if old_id.isdigit():
                return old_id
            counter += 1
            id_map[old_id] = str(counter)
        return id_map[old_id]

    for root, dirs, files in os.walk(dir_path):
        for file in files:
            if file.endswith(".py"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                
                new_content = content
                
                # ExecutionState("...", ...)
                new_content = re.sub(r'ExecutionState\((["\'])([^"\']+)\1', 
                                    lambda m: f'ExecutionState("{get_id(m.group(2))}"', new_content)
                
                # Event(execution_id="...", ...)
                new_content = re.sub(r'execution_id=(["\'])([^"\']+)\1', 
                                    lambda m: f'execution_id="{get_id(m.group(2))}"', new_content)

                # Event("...", ...) where first arg is execution_id
                new_content = re.sub(r'Event\((["\'])([^"\']+)\1', 
                                    lambda m: f'Event("{get_id(m.group(2))}"', new_content)
                
                # execution_id = "..."
                new_content = re.sub(r'execution_id\s*=\s*(["\'])([^"\']+)\1', 
                                    lambda m: f'execution_id = "{get_id(m.group(2))}"', new_content)

                if new_content != content:
                    with open(file_path, 'w') as f:
                        f.write(new_content)
                    print(f"Fixed execution IDs in {file_path}")

fix_execution_ids_v2("repos/noetl/tests")
