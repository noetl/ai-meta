import os
import glob

def replace_in_file(filepath, old, new):
    with open(filepath, "r") as f:
        content = f.read()
    if old in content:
        content = content.replace(old, new)
        with open(filepath, "w") as f:
            f.write(content)

test_files = glob.glob("repos/noetl/tests/unit/dsl/**/*.py", recursive=True)
for f in test_files:
    replace_in_file(f, "noetl.core.dsl.v2", "noetl.core.dsl.engine")

