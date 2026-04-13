import time
import sqlparse
commands_text = "INSERT INTO t VALUES ('" + "a"*5000000 + "');"
t0 = time.time()
stmts = sqlparse.split(commands_text)
print(f"sqlparse split 5MB: {time.time() - t0:.3f}s")
