import os
import glob
import re

dest_dir = "repos/noetl/noetl/server/api/v2"

# Instead of "from .core import *", we'll explicitly import everything using __import__ or just parse what we need.
# Wait, an easier fix is to just write a script that adds __all__ = list(locals().keys()) at the bottom of core.py? 
# No, __all__ must be defined.

# Actually, the easiest fix is to replace `from .core import *` with explicit imports, 
# or just change the python code to dynamically import or just read the variables.
# Even simpler: Just modify the imported files to set `__all__`.

for py_file in glob.glob(os.path.join(dest_dir, "*.py")):
    if py_file.endswith("__init__.py"):
        continue
    with open(py_file, "r") as f:
        content = f.read()
    
    # We can automatically build an __all__ list by finding all defined names
    # and appending __all__ = [...] at the end.
    
    # A quick way to bypass the underscore restriction without __all__ is to just
    # use `import module` and access things like `module._something`, but we already
    # have the code relying on globals.
    
    # Let's extract all top-level assignments and function/class defs.
    import ast
    try:
        tree = ast.parse(content)
        names = []
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                names.append(node.name)
            elif isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        names.append(target.id)
            elif isinstance(node, ast.AnnAssign):
                if isinstance(node.target, ast.Name):
                    names.append(node.target.id)
        
        if names:
            # Append __all__
            all_str = "\n__all__ = [" + ", ".join(f"'{name}'" for name in names) + "]\n"
            with open(py_file, "a") as f:
                f.write(all_str)
    except Exception as e:
        print(f"Failed to parse {py_file}: {e}")

