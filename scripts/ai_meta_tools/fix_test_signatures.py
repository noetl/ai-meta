import os
import re

def fix_test_signatures(dir_path):
    patterns = [
        (r'async def fake_load_playbook_by_id\(_catalog_id\):', 'async def fake_load_playbook_by_id(_catalog_id, *args, **kwargs):'),
        (r'async def _load_playbook_by_id\(_catalog_id, _conn=None\):', 'async def _load_playbook_by_id(_catalog_id, *args, **kwargs):'),
        (r'async def fake_save_state\(_state\):', 'async def fake_save_state(_state, *args, **kwargs):'),
        (r'async def fake_load_state\(_execution_id\):', 'async def fake_load_state(_execution_id, *args, **kwargs):'),
    ]

    for root, dirs, files in os.walk(dir_path):
        for file in files:
            if file.endswith(".py"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                
                new_content = content
                for pattern, repl in patterns:
                    new_content = re.sub(pattern, repl, new_content)

                if new_content != content:
                    with open(file_path, 'w') as f:
                        f.write(new_content)
                    print(f"Fixed signatures in {file_path}")

fix_test_signatures("repos/noetl/tests")
