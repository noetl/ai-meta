import os
import re

def fix_execution_ids(dir_path):
    counter = 99000
    id_map = {}

    def get_id(old_id):
        nonlocal counter
        if old_id not in id_map:
            counter += 1
            id_map[old_id] = str(counter)
        return id_map[old_id]

    # Pattern for execution_id="..." or execution_id='...'
    # where the value starts with a letter
    patterns = [
        (r'execution_id=(["\'])([a-zA-Z][^"\']*)\1', r'execution_id=\1{new_id}\1'),
        (r'ExecutionState\((["\'])([a-zA-Z][^"\']*)\1', r'ExecutionState(\1{new_id}\1'),
        (r'Event\((["\'])([a-zA-Z][^"\']*)\1', r'Event(\1{new_id}\1'),
    ]

    for root, dirs, files in os.walk(dir_path):
        for file in files:
            if file.endswith(".py"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                
                new_content = content
                for pattern, repl_fmt in patterns:
                    def replacer(match):
                        quote = match.group(1)
                        old_id = match.group(2)
                        new_id = get_id(old_id)
                        return repl_fmt.format(new_id=new_id).replace('\\1', quote)
                    
                    # Need to handle group references in format manually or use a smarter replacer
                    # Let's simplify
                    if "ExecutionState" in pattern:
                         new_content = re.sub(r'ExecutionState\((["\'])([a-zA-Z][^"\']*)\1', 
                                            lambda m: f'ExecutionState("{get_id(m.group(2))}"', new_content)
                    elif "Event" in pattern:
                         new_content = re.sub(r'Event\((["\'])([a-zA-Z][^"\']*)\1', 
                                            lambda m: f'Event("{get_id(m.group(2))}"', new_content)
                    else:
                         new_content = re.sub(r'execution_id=(["\'])([a-zA-Z][^"\']*)\1', 
                                            lambda m: f'execution_id="{get_id(m.group(2))}"', new_content)

                if new_content != content:
                    with open(file_path, 'w') as f:
                        f.write(new_content)
                    print(f"Fixed execution IDs in {file_path}")

fix_execution_ids("repos/noetl/tests")
