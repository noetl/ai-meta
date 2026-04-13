import re

filepath = "repos/noetl/noetl/server/app.py"
with open(filepath, "r") as f:
    content = f.read()

pattern = r"        @app\.get\(\"/\", include_in_schema=False\)[\s\S]*?else:\n        @app\.get\(\"/\", include_in_schema=False\)\n        async def root_no_ui\(\):\n            logger\.error\([^\n]*\n            return \{\"message\": \"NoETL API is running, but UI is not available\"\}\n"

new_content = """    @app.get("/", include_in_schema=False)
    async def root():
        return {"message": "NoETL API is running (Standalone GUI available externally)"}
"""

content = re.sub(pattern, new_content, content)

with open(filepath, "w") as f:
    f.write(content)
