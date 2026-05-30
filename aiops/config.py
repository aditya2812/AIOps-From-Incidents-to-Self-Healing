import os
from dotenv import load_dotenv

load_dotenv()

# ── Cluster ────────────────────────────────────────────────
NAMESPACE = "boutique"

# ── Telemetry endpoints (NodePort — accessible from localhost) ──
PROMETHEUS_URL  = "http://localhost:32001"
ALERTMANAGER_URL = "http://localhost:32002"

# ── Loki (ClusterIP — needs port-forward or internal access) ──
LOKI_URL        = "http://localhost:3100"

# ── Tempo ──────────────────────────────────────────────────
TEMPO_URL       = "http://localhost:32003"

# ── Redis (feedback store) ─────────────────────────────────
REDIS_HOST      = "localhost"
REDIS_PORT      = 6379

# ── Claude ─────────────────────────────────────────────────
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
CLAUDE_MODEL      = "claude-sonnet-4-20250514"

# ── Anomaly detection ──────────────────────────────────────
ANOMALY_CONFIDENCE_THRESHOLD = 0.80   # below this, suppress alert
ANOMALY_ZSCORE_THRESHOLD     = 2.5    # below this, not anomalous
BASELINE_LOOKBACK_MINUTES    = 60     # how far back to build baseline

# ── Remediation ────────────────────────────────────────────
AUTO_APPROVE_ENABLED = True           # set False for fully manual demo

# ── API ────────────────────────────────────────────────────
API_HOST = "0.0.0.0"
API_PORT = 8000
