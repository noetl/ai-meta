import time
commands_text = "INSERT INTO t VALUES ('" + "a"*5000000 + "');"
t0 = time.time()
statements = []
current = []
in_single = False
in_double = False
dollar_quote = False
dollar_tag = ""
i = 0
n = len(commands_text)
while i < n:
    ch = commands_text[i]
    if not in_single and not in_double and not dollar_quote:
        if ch == "'":
            in_single = True
        elif ch == '"':
            in_double = True
        elif ch == "$":
            j = i + 1
            tag = "$"
            while j < n and commands_text[j] != "$":
                tag += commands_text[j]
                j += 1
            if j < n:
                tag += "$"
                dollar_quote = True
                dollar_tag = tag
                current.append(tag)
                i = j + 1
                continue
        elif ch == ";":
            statements.append("".join(current))
            current = []
            i += 1
            continue
    else:
        if in_single and ch == "'":
            # Simple check for escaped quote
            if i + 1 < n and commands_text[i+1] == "'":
                current.append("''")
                i += 2
                continue
            in_single = False
        elif in_double and ch == '"':
            in_double = False
        elif dollar_quote and ch == "$":
            j = i + 1
            tag = "$"
            while j < n and commands_text[j] != "$":
                tag += commands_text[j]
                j += 1
            if j < n:
                tag += "$"
                if tag == dollar_tag:
                    dollar_quote = False
                    dollar_tag = ""
                    current.append(tag)
                    i = j + 1
                    continue
    current.append(ch)
    i += 1
if current:
    statements.append("".join(current))

print(f"python parse sql 5MB: {time.time() - t0:.3f}s")
