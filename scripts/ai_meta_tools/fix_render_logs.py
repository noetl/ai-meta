import re

with open("noetl/core/dsl/render.py", "r") as f:
    content = f.read()

# Remove noisy [TOJSON] logs
content = re.sub(r'            logger\.debug\(f"\[TOJSON\] unwrap_proxies: value_type=\{value_type\}"\)', '', content)
content = re.sub(r'                logger\.debug\(f"\[TOJSON\] Found TaskResultProxy, extracting _data"\)', '', content)
content = re.sub(r'                logger\.debug\(f"\[TOJSON\] Found proxy-like object with _data, extracting"\)', '', content)
content = re.sub(r'        logger\.debug\(f"\[TOJSON\] After unwrap, obj type=\{type\(obj\)\.__name__\}"\)', '', content)

with open("noetl/core/dsl/render.py", "w") as f:
    f.write(content)
