import httpx
import subprocess
import json
import anthropic
from typing import Optional
from agents.anomaly import Anomaly
from config import (
    PROMETHEUS_URL, LOKI_URL, CLAUDE_MODEL, ANTHROPIC_API_KEY
)

client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

class RCAAgent:

    def _loki_time_range(self, minutes: int):
        """Returns (start_ns, end_ns) as Unix nanosecond strings for Loki."""
        import time
        end_ns   = int(time.time() * 1e9)
        start_ns = int((time.time() - minutes * 60) * 1e9)
        return str(start_ns), str(end_ns)

    async def fetch_error_logs(self, service: str, minutes: int = 5) -> str:
        """Fetch recent error logs for the service from Loki."""
        try:
            start_ns, end_ns = self._loki_time_range(minutes)
            async with httpx.AsyncClient() as http:
                resp = await http.get(
                    f"{LOKI_URL}/loki/api/v1/query_range",
                    params={
                        "query": f'{{app="{service}"}}',
                        "start": start_ns,
                        "end":   end_ns,
                        "limit": 50
                    },
                    timeout=10
                )
                data    = resp.json()
                streams = data.get("data", {}).get("result", [])
                lines   = []
                for stream in streams:
                    for _, line in stream.get("values", []):
                        lower = line.lower()
                        if any(kw in lower for kw in
                               ["error","exception","panic","fatal","killed","oom","fail"]):
                            lines.append(line)
                if not lines:
                    return "No error logs found in the last 5 minutes."
                return "\n".join(lines[-20:])
        except Exception as e:
            return f"Could not fetch logs: {e}"

    async def fetch_recent_logs(self, service: str, minutes: int = 5) -> str:
        """Fetch all recent logs for context."""
        try:
            start_ns, end_ns = self._loki_time_range(minutes)
            async with httpx.AsyncClient() as http:
                resp = await http.get(
                    f"{LOKI_URL}/loki/api/v1/query_range",
                    params={
                        "query": f'{{app="{service}"}}',
                        "start": start_ns,
                        "end":   end_ns,
                        "limit": 20
                    },
                    timeout=10
                )
                data    = resp.json()
                streams = data.get("data", {}).get("result", [])
                lines   = []
                for stream in streams:
                    for _, line in stream.get("values", []):
                        lines.append(line)
                return "\n".join(lines[-15:]) if lines else "No recent logs found."
        except Exception as e:
            return f"Could not fetch logs: {e}"

    async def fetch_service_metrics(self, service: str, pod: str) -> dict:
        """Fetch current key metrics for the service from Prometheus."""
        metrics = {}
        queries = {
            "restart_count":    f'kube_pod_container_status_restarts_total{{pod="{pod}"}}',
            "memory_bytes":     f'container_memory_working_set_bytes{{pod="{pod}",container!=""}}',
            "memory_limit":     f'container_spec_memory_limit_bytes{{pod="{pod}",container!="",container!="POD"}}',
            "cpu_usage":        f'rate(container_cpu_usage_seconds_total{{pod="{pod}",container!=""}}[2m])',
            "pod_ready":        f'kube_pod_status_ready{{pod="{pod}",condition="true"}}',
        }
        async with httpx.AsyncClient() as http:
            for name, query in queries.items():
                try:
                    resp = await http.get(
                        f"{PROMETHEUS_URL}/api/v1/query",
                        params={"query": query},
                        timeout=5
                    )
                    results = resp.json().get("data", {}).get("result", [])
                    if results:
                        metrics[name] = float(results[0]["value"][1])
                    else:
                        metrics[name] = None
                except Exception:
                    metrics[name] = None
        return metrics

    async def fetch_pod_status(self, namespace: str, service: str) -> str:
        """
        Fetch pod container status directly from Kubernetes API.
        This is the PRIMARY signal for OOMKill — it never appears in app logs.
        kubectl get pod -o json gives us lastState.terminated.reason = OOMKilled
        """
        try:
            result = subprocess.run(
                ["kubectl", "get", "pod", "-n", namespace,
                 "-l", f"app={service}", "-o", "json"],
                capture_output=True, text=True, timeout=10
            )
            pods = json.loads(result.stdout).get("items", [])
            lines = []
            for pod in pods:
                name = pod["metadata"]["name"]
                for cs in pod["status"].get("containerStatuses", []):
                    last = cs.get("lastState", {}).get("terminated", {})
                    curr = cs.get("state", {})
                    restarts = cs.get("restartCount", 0)

                    curr_state = "running" if "running" in curr else                                  "terminated" if "terminated" in curr else                                  "waiting" if "waiting" in curr else "unknown"
                    waiting_reason = curr.get("waiting", {}).get("reason", "")

                    lines.append(f"pod: {name}")
                    lines.append(f"  restart_count:    {restarts}")
                    lines.append(f"  current_state:    {curr_state}")
                    if waiting_reason:
                        lines.append(f"  waiting_reason:   {waiting_reason}")

                    if last:
                        reason   = last.get("reason", "unknown")
                        exitcode = last.get("exitCode", "unknown")
                        lines.append(f"  last_terminated:  reason={reason} exitCode={exitcode}")
                        if reason == "OOMKilled":
                            lines.append(f"  ⚠ OOM_CONFIRMED:  Container killed by kernel OOMKiller")
                            lines.append(f"  ⚠ EXIT_CODE_137:  Confirms OOMKill — NOT an app crash")
                            lines.append(f"  ⚠ ROOT_CAUSE:     Memory limit is too low for this service")

            return "\n".join(lines) if lines else "No pod status available"
        except Exception as e:
            return f"Could not fetch pod status: {e}"

    def format_metrics(self, metrics: dict) -> str:
        """Format metrics dict into readable string for the prompt."""
        lines = []
        mem   = metrics.get("memory_bytes")
        limit = metrics.get("memory_limit")

        if mem is not None:
            lines.append(f"memory_used:    {mem/1024/1024:.1f} MB")
        if limit and limit > 0:
            lines.append(f"memory_limit:   {limit/1024/1024:.1f} MB")
        if mem and limit and limit > 0:
            lines.append(f"memory_pct:     {mem/limit*100:.1f}%")

        cpu = metrics.get("cpu_usage")
        if cpu is not None:
            lines.append(f"cpu_usage:      {cpu*100:.2f}%")

        restarts = metrics.get("restart_count")
        if restarts is not None:
            lines.append(f"restart_count:  {int(restarts)}")

        ready = metrics.get("pod_ready")
        if ready is not None:
            lines.append(f"pod_ready:      {'yes' if ready == 1 else 'no'}")

        return "\n".join(lines) if lines else "No metrics available."

    def build_prompt(
        self,
        anomaly:          Anomaly,
        error_logs:       str,
        recent_logs:      str,
        metrics:          str,
        dep_graph:        dict,
        past_corrections: str,
        alert_hint:       str = "",
        pod_status:       str = ""
    ) -> str:
        """
        Assembles all context into the RCA prompt.
        The quality of this prompt determines the quality of the diagnosis.
        """
        downstream = [
            e["to"] for e in dep_graph.get("edges", [])
            if e["from"] == anomaly.service
        ]
        upstream = [
            e["from"] for e in dep_graph.get("edges", [])
            if e["to"] == anomaly.service
        ]

        return f"""You are an expert SRE performing root cause analysis on a production incident.
Think step by step before reaching a conclusion.

{alert_hint}


## Anomaly detected
Service:        {anomaly.service}
Pod:            {anomaly.pod}
Metric:         {anomaly.metric}
Current value:  {anomaly.current_value}
Normal range:   {anomaly.baseline_mean:.2f} ± {anomaly.baseline_std:.2f}
Z-score:        {anomaly.z_score}
Confidence:     {anomaly.confidence*100:.0f}%

## Current metrics
{metrics}

## Upstream dependencies (services this one calls)
{", ".join(upstream) if upstream else "none"}

## Downstream services at risk (services that call this one)
{", ".join(downstream) if downstream else "none"}

## Pod container status (from Kubernetes API — most reliable OOM signal)
{pod_status}

## Error logs (last 5 minutes)
{error_logs}

## Recent logs (last 5 minutes)
{recent_logs}

{past_corrections}

## Instructions
1. Identify the most likely root cause. Be specific — name the exact failure mode.
   IMPORTANT: If restart_count > 0 and memory limit exists, check if OOMKill is the cause.
   If memory_pct > 80% or memory limit is very low (< 64Mi), strongly consider OOMKilled as root cause.
   If last_terminated_reason is OOMKilled, that IS the root cause.
2. Consider whether upstream dependencies could be causing this.
3. Assess which downstream services are affected.
4. Recommend exactly ONE action from this list:
   - restart       (pod is crash-looping or has a transient error)
   - scale_up      (pod is overwhelmed by traffic)
   - increase_memory_limit  (pod is OOMKilled, limit is too low)
   - notify_only   (unknown cause, needs human investigation)

Respond ONLY with valid JSON. No markdown, no explanation outside the JSON:
{{
  "root_cause":          "one specific sentence",
  "confidence":          0-100,
  "affected_services":   ["{anomaly.service}"],
  "recommended_action":  "restart|scale_up|increase_memory_limit|notify_only",
  "reasoning":           "2-3 sentences explaining your diagnosis in plain English for the dashboard",
  "severity":            "critical|high|medium"
}}"""

    async def analyze(
        self,
        anomaly:          Anomaly,
        dep_graph:        dict,
        past_corrections: str = "",
        alert_context:    dict = None
    ) -> Optional[dict]:
        """
        Main entry point — called by orchestrator after anomaly is confirmed.
        Returns structured RCA dict or None on failure.
        """
        print(f"[rca] analyzing {anomaly.service} — {anomaly.metric}")

        # Gather all context in parallel
        error_logs   = await self.fetch_error_logs(anomaly.service)
        recent_logs  = await self.fetch_recent_logs(anomaly.service)
        metrics_raw  = await self.fetch_service_metrics(anomaly.service, anomaly.pod)
        metrics_str  = self.format_metrics(metrics_raw)
        pod_status   = await self.fetch_pod_status("boutique", anomaly.service)

        # Inject alert-level context directly into prompt
        # This ensures Claude knows the OOMKill reason even if logs have rotated
        alert_hint = ""
        if alert_context:
            alertname = alert_context.get("alertname", "")
            if "OOMKilled" in alertname:
                alert_hint = (
                    "⚠ DIRECT ALERT CONTEXT: "
                    "kube-state-metrics reports this pod was terminated with reason=OOMKilled. "
                    "The container exceeded its memory limit and was killed by the kernel. "
                    "Memory limit is likely too low. recommended_action MUST be increase_memory_limit."
                )
            elif "Restarting" in alertname:
                alert_hint = (
                    "⚠ DIRECT ALERT CONTEXT: "
                    f"Pod restart count has increased. Check if this is OOMKill or application crash."
                )

        prompt = self.build_prompt(
            anomaly, error_logs, recent_logs,
            metrics_str, dep_graph, past_corrections,
            alert_hint, pod_status
        )

        print(f"[rca] calling Claude API...")

        try:
            response = client.messages.create(
                model=CLAUDE_MODEL,
                max_tokens=1024,
                messages=[{"role": "user", "content": prompt}]
            )
            raw = response.content[0].text.strip()
            print(f"[rca] Claude response received")

            # Parse JSON — strip any accidental markdown fences
            if "```" in raw:
                raw = raw.split("```")[1]
                if raw.startswith("json"):
                    raw = raw[4:]
            raw = raw.strip()

            result = json.loads(raw)

            # Ensure affected_services always includes the anomaly service
            if anomaly.service not in result.get("affected_services", []):
                result["affected_services"].insert(0, anomaly.service)

            return result

        except json.JSONDecodeError as e:
            print(f"[rca] JSON parse error: {e}\nRaw: {raw[:200]}")
            return {
                "root_cause":         "Claude response could not be parsed",
                "confidence":         0,
                "affected_services":  [anomaly.service],
                "recommended_action": "notify_only",
                "reasoning":          "RCA agent received an unparseable response. Manual investigation required.",
                "severity":           "high"
            }
        except Exception as e:
            print(f"[rca] error: {e}")
            return None
