import os
import re

def fix_playbook_models_v2(dir_path):
    for root, dirs, files in os.walk(dir_path):
        for file in files:
            if file.endswith(".py"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                
                new_content = content
                
                # 1. Fix "next": [...] -> "next": {"arcs": [...]}
                new_content = re.sub(r'"next":\s*\[\s*(\{.*?\})\s*\]', r'"next": {"arcs": [\1]}', new_content, flags=re.DOTALL)
                
                # 2. Fix "args" -> "input" in workflow steps
                # Pattern: "step": "...", (maybe other fields), "args": {
                new_content = re.sub(r'("step":\s*"[^"]+",.*?"args":\s*\{)', lambda m: m.group(1).replace('"args":', '"input":'), new_content, flags=re.DOTALL)
                
                # Simple replacement for "args" to "input" if it's inside a step dict
                # This is risky but let's see.
                # Actually, "args" is mostly used for steps in tests.
                
                if new_content != content:
                    with open(file_path, 'w') as f:
                        f.write(new_content)
                    print(f"Fixed playbook models in {file_path}")

fix_playbook_models_v2("repos/noetl/tests")
