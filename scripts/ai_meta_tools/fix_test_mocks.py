import os
import re

def fix_mocks(dir_path):
    for root, dirs, files in os.walk(dir_path):
        for file in files:
            if file.endswith(".py"):
                file_path = os.path.join(root, file)
                with open(file_path, 'r') as f:
                    content = f.read()
                
                # Find classes ending in Cache
                matches = list(re.finditer(r'^( +|)(class \w*Cache:)', content, re.MULTILINE))
                if matches:
                    new_content = content
                    offset = 0
                    for match in matches:
                        indent = match.group(1)
                        class_decl = match.group(2)
                        methods = f"\n{indent}    async def get_loop_collection(self, *args, **kwargs): return None\n{indent}    async def save_loop_collection(self, *args, **kwargs): pass"
                        pos = match.end() + offset
                        new_content = new_content[:pos] + methods + new_content[pos:]
                        offset += len(methods)
                    
                    with open(file_path, 'w') as f:
                        f.write(new_content)

fix_mocks("repos/noetl/tests")
