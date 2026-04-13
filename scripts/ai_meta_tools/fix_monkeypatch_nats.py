import os
import re

def fix_monkeypatch_nats(dir_path):
    patterns = [
        (r'monkeypatch.setattr\(engine_module, ["\']get_nats_cache["\'],', 'monkeypatch.setattr("noetl.core.cache.nats_kv.get_nats_cache",'),
        (r'monkeypatch.setattr\(engine, ["\']get_nats_cache["\'],', 'monkeypatch.setattr("noetl.core.cache.nats_kv.get_nats_cache",'),
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
                    print(f"Fixed monkeypatch in {file_path}")

fix_monkeypatch_nats("repos/noetl/tests")
