import time
commands_text = "INSERT INTO t VALUES ('" + "a"*5000000 + "');"
t0 = time.time()
statements = []
i = 0
n = len(commands_text)
start = 0
while i < n:
    # Use find to skip boring characters
    next_quote = commands_text.find("'", i)
    next_double = commands_text.find('"', i)
    next_dollar = commands_text.find('$', i)
    next_semi = commands_text.find(';', i)
    
    # Filter out -1 and find minimum
    candidates = []
    if next_quote != -1: candidates.append(next_quote)
    if next_double != -1: candidates.append(next_double)
    if next_dollar != -1: candidates.append(next_dollar)
    if next_semi != -1: candidates.append(next_semi)
    
    if not candidates:
        statements.append(commands_text[start:])
        break
        
    i = min(candidates)
    ch = commands_text[i]
    
    if ch == ';':
        statements.append(commands_text[start:i])
        start = i + 1
        i += 1
    elif ch == "'":
        # Find closing quote
        i = commands_text.find("'", i + 1)
        while i != -1 and i + 1 < n and commands_text[i+1] == "'":
            i = commands_text.find("'", i + 2)
        if i == -1: i = n
        else: i += 1
    elif ch == '"':
        i = commands_text.find('"', i + 1)
        if i == -1: i = n
        else: i += 1
    elif ch == '$':
        # Find end of dollar tag
        end_tag = commands_text.find('$', i + 1)
        if end_tag == -1:
            i = n
        else:
            tag = commands_text[i:end_tag+1]
            i = commands_text.find(tag, end_tag + 1)
            if i == -1: i = n
            else: i += len(tag)

if start < n:
    stmt = commands_text[start:].strip()
    if stmt:
        statements.append(stmt)

print(f"fast parse sql 5MB: {time.time() - t0:.3f}s")
