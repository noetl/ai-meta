import re

with open("noetl/worker/keychain_resolver.py", "r") as f:
    content = f.read()

# Replace the inefficient task_str = str(task_config) with a better check
old_check = """    # Quick check for keychain references in string values to avoid deep scan if possible
    # This is a optimization for cases with NO keychain references
    task_str = str(task_config)
    if 'keychain.' not in task_str:
        return context"""

new_check = """    # Optimization: skip scanning if context already has recent keychain data 
    # and config is large/unlikely to contain new refs.
    # In task sequences, refs are usually in the first few keys.
    # We use a more efficient scan that avoids stringifying the entire payload.
    def has_keychain_ref(obj) -> bool:
        if isinstance(obj, str):
            return 'keychain.' in obj
        if isinstance(obj, dict):
            # Only scan keys and shallow values first
            for k, v in obj.items():
                if 'keychain.' in k: return True
                if isinstance(v, str) and 'keychain.' in v: return True
            # Then deep scan if small
            if len(obj) < 100:
                return any(has_keychain_ref(v) for v in obj.values())
        if isinstance(obj, (list, tuple)) and len(obj) < 100:
            return any(has_keychain_ref(i) for i in obj)
        return False

    if not has_keychain_ref(task_config):
        return context"""

content = content.replace(old_check, new_check)

with open("noetl/worker/keychain_resolver.py", "w") as f:
    f.write(content)
