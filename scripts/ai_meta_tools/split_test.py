import re

def fast_split_sql(sql: str) -> list[str]:
    """Split SQL on semicolons that are outside of strings."""
    # Fast path: if there is only one or zero semicolons (or none inside the string)
    # just return it.
    if sql.count(';') <= 1:
        s = sql.strip().strip(';')
        return [s] if s else []
        
    statements = []
    # Match:
    # 1. '...' (single quote string, allows '')
    # 2. "..." (double quote string, allows "")
    # 3. $tag$...$tag$ (dollar quoted string)
    # 4. --... (single line comment)
    # 5. /*...*/ (multi-line comment)
    # 6. ; (the separator)
    # 7. anything else
    
    pattern = re.compile(
        r"('(?:''|[^'])*')|"
        r'("(?:""|[^"])*")|'
        r'(\$[a-zA-Z0-9_]*\$.*?\1)|'
        r'(--[^\n]*)|'
        r'(/\*.*?\*/)|'
        r'(;)|'
        r'([^;\'"$-/]+|.)',
        re.DOTALL
    )
    
    current = []
    for match in pattern.finditer(sql):
        if match.group(6):  # The semicolon
            stmt = ''.join(current).strip()
            if stmt:
                statements.append(stmt)
            current.clear()
        elif match.group(4) or match.group(5):
            pass # ignore comments
        else:
            current.append(match.group(0))
            
    if current:
        stmt = ''.join(current).strip()
        if stmt:
            statements.append(stmt)
            
    return statements

sql = "SELECT 'hello;world'; INSERT INTO t VALUES ('a''b;c');"
print(fast_split_sql(sql))
import time
commands_text = "INSERT INTO t VALUES ('" + "a;a"*1000000 + "');"
t0 = time.time()
print(len(fast_split_sql(commands_text)))
print(f"fast parse sql 5MB: {time.time() - t0:.3f}s")
