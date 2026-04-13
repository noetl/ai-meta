import re

with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

new_init_block = """    def __init__(self, nats_url: str, server_url: str, worker_id: str):
        \"\"\"Initialize Core worker.\"\"\"
        from noetl.core.config import get_worker_settings
        worker_settings = get_worker_settings()
        
        self.nats_url = nats_url
        self.server_url = server_url
        self.worker_id = worker_id
        self._running = False
        self._registered = False
        self._http_client = httpx.AsyncClient(timeout=30.0)
        self._nats_client = None
        self._kv = None
        self._current_execution_id = None
        self._last_db_throttle_log_at = 0.0
        self._recent_command_activity: dict[str, float] = {}
        self._recent_command_activity_last_prune_monotonic = time.monotonic()
        
        # Throttling and concurrency control
        self._max_inflight_commands = max(1, int(worker_settings.max_inflight_commands))
        self._max_inflight_db_commands = max(1, int(os.getenv("NOETL_WORKER_DB_SEMAPHORE", "16")))
        self._db_command_semaphore = asyncio.Semaphore(self._max_inflight_db_commands)
        self._postgres_pool_waiting_threshold = int(os.getenv("NOETL_POSTGRES_POOL_WAITING_THRESHOLD", "4"))
        
        self._command_heartbeat_interval = max(
            1,
            int(os.getenv("NOETL_COMMAND_HEARTBEAT_INTERVAL_SECONDS", "10")),
        )
        self._command_heartbeat_timeout = max(
            1,
            int(os.getenv("NOETL_COMMAND_HEARTBEAT_TIMEOUT_SECONDS", "3")),
        )
        self._command_heartbeat_max_retries = max(
            1,
            int(os.getenv("NOETL_COMMAND_HEARTBEAT_MAX_RETRIES", "1")),
        )
        # Adaptive AIMD concurrency controller
        self._concurrency = AdaptiveConcurrencyController(
            initial_limit=max(1.0, float(self._max_inflight_commands) / 2.0),
            min_limit=1.0,
            max_limit=float(self._max_inflight_commands),
            probe_interval=worker_settings.concurrency_probe_interval,
        )
        # Pre-initialize Jinja2 environment for reuse
        self._jinja_env = Environment(loader=BaseLoader())
        self._jinja_env = add_b64encode_filter(self._jinja_env)
"""

pattern = r'    def __init__\(self, nats_url: str, server_url: str, worker_id: str\):.*?self\._concurrency = AdaptiveConcurrencyController\(.*?\n\s+\)'
content = re.sub(pattern, new_init_block, content, flags=re.DOTALL)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
