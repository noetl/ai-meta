import re

filepath = "repos/noetl/noetl/server/app.py"
with open(filepath, "r") as f:
    content = f.read()

content = content.replace("    if enable_ui is None:\n\n", "")
content = content.replace("def _create_app(settings: Settings, enable_ui: Optional[bool] = None) -> FastAPI:", "def _create_app(settings: Settings) -> FastAPI:")
content = content.replace("    return _create_app(settings=settings, enable_ui=enable_ui)", "    return _create_app(settings=settings)")

with open(filepath, "w") as f:
    f.write(content)
