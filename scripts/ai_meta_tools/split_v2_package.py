import os
import shutil

src_file = "repos/noetl/noetl/server/api/v2.py"
dest_dir = "repos/noetl/noetl/server/api/v2"

if not os.path.exists(dest_dir):
    os.makedirs(dest_dir)

with open(src_file, "r") as f:
    content = f.read()

# Instead of parsing everything manually, I will use sed or awk or just python to extract.
# Actually, since I have the content, I can just write the modules manually with the correct imports.
# It is better to write a script that has the content of each file as a string.
