from datetime import datetime

ts1 = datetime.fromisoformat("2026-04-10 12:29:50.138797+00:00")
ts2 = datetime.utcnow()
print(f"Elapsed: {(ts2.replace(tzinfo=ts1.tzinfo) - ts1).total_seconds()} seconds")
