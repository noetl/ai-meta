import re
import time

pattern = re.compile(
        r"('(?:''|\\.|[^'])*')|"            # 1: Single quote strings
        r'("(?:""|\\.|[^"])*")|'            # 2: Double quote strings
        r'((\$[a-zA-Z0-9_]*\$).*?\4)|'      # 3,4: Dollar quoted strings
        r'(--[^\n]*)|'                      # 5: Single-line comments
        r'(/\*.*?\*/)|'                     # 6: Multi-line comments
        r'(;)|'                             # 7: Semicolons
        r'([^;\'"$-/]+|.)',                 # 8: Anything else
        re.DOTALL
    )

commands_text = "INSERT INTO t VALUES ('" + "a;a"*1000000 + "');"

t0 = time.time()
for match in pattern.finditer(commands_text):
    pass
print(f"Time: {time.time() - t0:.3f}s")
