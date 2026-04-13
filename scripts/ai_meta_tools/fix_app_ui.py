import re

filepath = "repos/noetl/noetl/server/app.py"
with open(filepath, "r") as f:
    content = f.read()

# Delete the whole enable_ui block
pattern = r"    if enable_ui and ui_build_path\.exists\(\):[\s\S]*?raise HTTPException\(status_code=404, detail=\"API endpoint not found\"\)\n            return FileResponse\([\s\S]*?\"Expires\": \"0\"\n                \}\n            \)\n"
content = re.sub(pattern, "", content)

# Also find and remove the ui_build_path and enable_ui variable definitions if they exist, or just leave them.
content = re.sub(r"\s*enable_ui = [^\n]*\n", "\n", content)
content = re.sub(r"\s*ui_build_path = [^\n]*\n", "\n", content)

with open(filepath, "w") as f:
    f.write(content)
