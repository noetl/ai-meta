import os
import re

def fix_playbook_models(dir_path):
    for root, dirs, files in os.walk(dir_path):
        for file in files:
            if file.endswith(".py"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                
                new_content = content
                
                # 1. Fix "next": [...] -> "next": {"arcs": [...]}
                # This is tricky because of multi-line and nested stuff
                # In tests, they are mostly on one line or simple multi-line
                
                # Pattern: "next": [ { ... } ]
                new_content = re.sub(r'"next":\s*\[\s*(\{.*?\})\s*\]', r'"next": {"arcs": [\1]}', new_content, flags=re.DOTALL)
                
                # Pattern: "next": [ {"step": "..."} ]
                new_content = re.sub(r'"next":\s*\[\s*(\{"step":\s*"[^"]+"\}\s*)\s*\]', r'"next": {"arcs": [\1]}', new_content)

                if new_content != content:
                    with open(file_path, 'w') as f:
                        f.write(new_content)
                    print(f"Fixed playbook models in {file_path}")

fix_playbook_models("repos/noetl/tests")
