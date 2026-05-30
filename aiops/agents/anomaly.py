import httpx
import numpy as np
from dataclasses import dataclass
from typing import Optional, Tuple, List
from config import PROMETHEUS_URL, NAMESPACE, ANOMALY_CONFIDENCE_THRESHOLD, BASELINE_LOOKBACK_MINUTES

@dataclass
class Anomaly:
    service:        str
    pod:            str
    metric:         str
    current_value:  float
    baseline_mean:  float
    baseline_std:   float
    z_score:        float
    confidence:     float

    def summary(self) -> str:
        return (
            f"{self.metric} on {self.pod} = {self.current_value:.1f} "
            f"(normal: {self.baseline_mean:.1f} ± {self.baseline_std:.1f}, "
            f"z={self.z_score:.1f}, confidence={self.confidence*100:.0f}%)"
        )

class AnomalyAgent:

    async def fetch_metric_history(self, query: str) -> List[float]:
        """Pull last N minutes of metric values from Prometheus."""
        async with httpx.AsyncClient() as client:
            resp = await client.get(
                f"{PROMETHEUS_URL}/api/v1/query_range",
                params={
                    "query": query,
                    "start": f"{BASELINE_LOOKBACK_MINUTES}m",   # relative to now
                    "end":   "0m",
                    "step":  "30s"
                },
                timeout=10
            )
            data = resp.json()
            results = data.get("data", {}).get("result", [])
            if not results:
                return []
            # Flatten all series values
            values = []
            for series in results:
                values.extend([float(v[1]) for v in series["values"]])
            return values

    def compute_zscore(self, current: float, history: list[float]) -> Tuple[float, float]:
        """
        Returns (z_score, confidence).
        Confidence uses a sigmoid so:
          z=2.0 → ~50%
          z=2.5 → ~73%
          z=3.0 → ~88%
          z=4.0 → ~97%
        """
        if len(history) < 10:
            return 0.0, 0.0

        mean = float(np.mean(history))
        std  = float(np.std(history))

        if std < 0.001:          # metric is flat — no variance to detect against
            return 0.0, 0.0

        z          = abs((current - mean) / std)
        confidence = float(1 / (1 + np.exp(-(z - 2.5))))

        return round(z, 2), round(confidence, 3)

    async def fetch_current_metric(self, query: str) -> "float | None":
        """Get the current (instant) value of a metric."""
        async with httpx.AsyncClient() as client:
            resp = await client.get(
                f"{PROMETHEUS_URL}/api/v1/query",
                params={"query": query},
                timeout=10
            )
            data    = resp.json()
            results = data.get("data", {}).get("result", [])
            if not results:
                return None
            return float(results[0]["value"][1])

    async def analyze(self, alert: dict) -> Optional[Anomaly]:
        """
        Entry point — called by orchestrator when Alertmanager fires.
        Returns Anomaly if genuine, None if noise.
        """
        labels      = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alertname   = labels.get("alertname", "")
        pod         = labels.get("pod", "")
        namespace   = labels.get("namespace", NAMESPACE)

        # Only process boutique namespace
        if namespace != NAMESPACE or "loadgenerator" in pod:
            return None

        # Map alert type to the right metric query
        metric_query, metric_name = self._get_metric_for_alert(alertname, pod, namespace)
        if not metric_query:
            return None

        # Get current value
        current = await self.fetch_current_metric(metric_query)
        if current is None:
            return None

        # Get baseline history
        history = await self.fetch_metric_history(metric_query)
        if len(history) < 10:
            # Not enough history — pass through with medium confidence
            return Anomaly(
                service=self._pod_to_service(pod),
                pod=pod,
                metric=metric_name,
                current_value=current,
                baseline_mean=current,
                baseline_std=0,
                z_score=0,
                confidence=0.75      # assume genuine if no baseline yet
            )

        z, confidence = self.compute_zscore(current, history)

        # Suppress if below threshold — this is the noise filter
        if confidence < ANOMALY_CONFIDENCE_THRESHOLD:
            print(f"[anomaly] suppressed {alertname} on {pod} — "
                  f"confidence {confidence:.2f} below threshold {ANOMALY_CONFIDENCE_THRESHOLD}")
            return None

        return Anomaly(
            service=self._pod_to_service(pod),
            pod=pod,
            metric=metric_name,
            current_value=current,
            baseline_mean=float(np.mean(history)),
            baseline_std=float(np.std(history)),
            z_score=z,
            confidence=confidence
        )

    def _get_metric_for_alert(self, alertname: str, pod: str, namespace: str) -> Tuple[str, str]:
        """Map alert name to PromQL query + human readable metric name."""
        queries = {
            "BoutiquePodOOMKilled": (
                f'kube_pod_container_status_restarts_total{{namespace="{namespace}",pod="{pod}"}}',
                "restart_count"
            ),
            "BoutiquePodRestarting": (
                f'kube_pod_container_status_restarts_total{{namespace="{namespace}",pod="{pod}"}}',
                "restart_count"
            ),
            "BoutiqueHighMemory": (
                f'container_memory_working_set_bytes{{namespace="{namespace}",pod="{pod}",container!=""}}',
                "memory_bytes"
            ),
            "BoutiquePodNotReady": (
                f'kube_pod_status_ready{{namespace="{namespace}",pod="{pod}",condition="true"}}',
                "pod_ready"
            ),
        }
        return queries.get(alertname, (None, None))

    def _pod_to_service(self, pod: str) -> str:
        """Extract service name from pod name.
        e.g. cartservice-95b44968c-rr8qf → cartservice
        """
        parts = pod.split("-")
        # Pod name format: <service>-<replicaset-hash>-<pod-hash>
        # Drop last two parts
        if len(parts) >= 3:
            return "-".join(parts[:-2])
        return pod
