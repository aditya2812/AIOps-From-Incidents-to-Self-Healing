import time
import asyncio
from typing import Optional
from agents.anomaly import AnomalyAgent, Anomaly
from agents.rca import RCAAgent
from agents.remediation import RemediationAgent, RemediationProposal
from agents.feedback import FeedbackStore
from config import NAMESPACE

DEP_GRAPH = {
    "nodes": [
        {"id": "frontend",              "critical": True},
        {"id": "cartservice",           "critical": True},
        {"id": "checkoutservice",       "critical": True},
        {"id": "paymentservice",        "critical": True},
        {"id": "emailservice",          "critical": False},
        {"id": "shippingservice",       "critical": False},
        {"id": "currencyservice",       "critical": False},
        {"id": "productcatalogservice", "critical": True},
        {"id": "recommendationservice", "critical": False},
        {"id": "adservice",             "critical": False},
        {"id": "redis-cart",            "critical": True},
    ],
    "edges": [
        {"from": "frontend",              "to": "cartservice"},
        {"from": "frontend",              "to": "productcatalogservice"},
        {"from": "frontend",              "to": "recommendationservice"},
        {"from": "frontend",              "to": "currencyservice"},
        {"from": "frontend",              "to": "checkoutservice"},
        {"from": "frontend",              "to": "adservice"},
        {"from": "frontend",              "to": "shippingservice"},
        {"from": "checkoutservice",       "to": "cartservice"},
        {"from": "checkoutservice",       "to": "paymentservice"},
        {"from": "checkoutservice",       "to": "emailservice"},
        {"from": "checkoutservice",       "to": "shippingservice"},
        {"from": "checkoutservice",       "to": "currencyservice"},
        {"from": "checkoutservice",       "to": "productcatalogservice"},
        {"from": "cartservice",           "to": "redis-cart"},
        {"from": "recommendationservice", "to": "productcatalogservice"},
    ]
}

class Orchestrator:

    def __init__(self):
        self.anomaly_agent     = AnomalyAgent()
        self.rca_agent         = RCAAgent()
        self.remediation_agent = RemediationAgent()
        self.feedback_store    = FeedbackStore()
        self.dep_graph         = DEP_GRAPH
        self.incidents         = []
        self._recent_alerts    = {}
        self._remediation_cooldown = {}
        self._suppress_until   = 0     # demo mode: suppress all until this time

    def suppress_alerts(self, seconds: int = 45):
        """Call after restore to suppress noisy recovery alerts."""
        import time
        self._suppress_until = time.time() + seconds
        print(f"[orchestrator] suppressing alerts for {seconds}s")

    def _is_duplicate(self, alert: dict) -> bool:
        key = (
            alert.get("labels", {}).get("alertname", ""),
            alert.get("labels", {}).get("pod", "")
        )
        now  = time.time()
        last = self._recent_alerts.get(key, 0)
        if now - last < 60:
            return True
        self._recent_alerts[key] = now
        return False

    def _is_cooling_down(self, service: str) -> bool:
        """Prevent remediating the same service more than once per 3 minutes."""
        now  = time.time()
        last = self._remediation_cooldown.get(service, 0)
        if now - last < 60:
            print(f"[orchestrator] cooldown active for {service} — skipping")
            return True
        return False

    async def on_alert(self, alert: dict) -> Optional[dict]:
        alertname = alert.get("labels", {}).get("alertname", "unknown")
        pod       = alert.get("labels", {}).get("pod", "unknown")
        namespace = alert.get("labels", {}).get("namespace", "")

        # Demo mode suppression — ignore all alerts during recovery window
        if time.time() < self._suppress_until:
            print(f"[orchestrator] suppressed (recovery window): {alertname}")
            return None

        # Only process boutique namespace
        if namespace != NAMESPACE:
            return None

        # Skip noisy services
        if "loadgenerator" in pod or "redis-cart" in pod:
            return None

        # Skip BoutiquePodNotReady — fires before OOMKill is recorded
        # Only process OOMKilled — most specific signal for our demo
        # BoutiquePodRestarting and BoutiquePodNotReady are too generic
        ALLOWED = {"BoutiquePodOOMKilled", "BoutiqueHighMemory"}
        if alertname not in ALLOWED:
            print(f"[orchestrator] skipping {alertname} — not in allowed list")
            return None

        print(f"\n[orchestrator] alert received: {alertname} on {pod}")

        if self._is_duplicate(alert):
            print(f"[orchestrator] duplicate suppressed: {alertname} on {pod}")
            return None

        # Step 1: anomaly agent
        print(f"[orchestrator] step 1 — anomaly detection")
        anomaly = await self.anomaly_agent.analyze(alert)
        if not anomaly:
            print(f"[orchestrator] suppressed by anomaly agent")
            return None

        print(f"[orchestrator] anomaly confirmed: {anomaly.summary()}")

        # Check cooldown AFTER anomaly confirmation
        # OOMKilled is high-value — always bypass cooldown
        oom_alert = alertname in ("BoutiquePodOOMKilled", "BoutiqueHighMemory")
        if not oom_alert and self._is_cooling_down(anomaly.service):
            return None

        # Step 2: feedback corrections
        print(f"[orchestrator] step 2 — fetching past corrections")
        past_corrections = self.feedback_store.get_corrections_for_service(
            anomaly.service
        )

        # Step 3: RCA — pass alert context so Claude knows OOMKill reason directly
        print(f"[orchestrator] step 3 — root cause analysis")
        alert_context = {"alertname": alertname, "pod": pod}
        rca = await self.rca_agent.analyze(
            anomaly, DEP_GRAPH, past_corrections, alert_context
        )
        if not rca:
            rca = {
                "root_cause":         "RCA agent failed",
                "confidence":         0,
                "affected_services":  [anomaly.service],
                "recommended_action": "notify_only",
                "reasoning":          "Automated diagnosis failed.",
                "severity":           "high"
            }

        print(f"[orchestrator] RCA: {rca['root_cause']} ({rca['confidence']}% confidence)")

        # Step 4: remediation proposal
        print(f"[orchestrator] step 4 — remediation proposal")
        proposal = self.remediation_agent.propose(rca)
        print(f"[orchestrator] proposed: {proposal.action} (auto={proposal.auto_approve})")

        # Step 5: build incident
        incident_id = f"inc-{int(time.time())}"
        incident = {
            "id":        incident_id,
            "timestamp": time.time(),
            "alertname": alertname,
            "anomaly": {
                "service":       anomaly.service,
                "pod":           anomaly.pod,
                "metric":        anomaly.metric,
                "current_value": anomaly.current_value,
                "baseline_mean": anomaly.baseline_mean,
                "z_score":       anomaly.z_score,
                "confidence":    anomaly.confidence
            },
            "rca":      rca,
            "proposal": {
                "action":       proposal.action,
                "command":      proposal.command,
                "auto_approve": proposal.auto_approve,
                "risk":         proposal.risk
            },
            "status":    "pending_approval",
            "execution": None,
            "feedback":  None
        }

        # Step 6: execute if auto-approved
        if proposal.auto_approve:
            print(f"[orchestrator] auto-executing: {proposal.command}")
            result = self.remediation_agent.execute(proposal)
            incident["execution"] = result
            incident["status"]    = "remediated" if result["status"] == "success" \
                                    else "execution_failed"
            # Set cooldown after successful remediation
            if result["status"] == "success":
                self._remediation_cooldown[anomaly.service] = time.time()
            print(f"[orchestrator] execution: {result['status']}")
        else:
            incident["status"] = "pending_approval"
            print(f"[orchestrator] waiting for human approval")

        # Step 7: store — keep max 20
        self.incidents.insert(0, incident)
        if len(self.incidents) > 20:
            self.incidents = self.incidents[:20]

        print(f"[orchestrator] incident {incident_id} — status: {incident['status']}")
        return incident

    def approve_remediation(self, incident_id: str) -> dict:
        incident = next(
            (i for i in self.incidents if i["id"] == incident_id), None
        )
        if not incident:
            return {"error": f"incident {incident_id} not found"}
        if incident["status"] == "remediated":
            return {"error": "already remediated"}
        proposal = RemediationProposal(
            action=incident["proposal"]["action"],
            command=incident["proposal"]["command"],
            auto_approve=True,
            risk=incident["proposal"]["risk"]
        )
        result = self.remediation_agent.execute(proposal)
        incident["execution"] = result
        incident["status"]    = "remediated" if result["status"] == "success" \
                                else "execution_failed"
        if result["status"] == "success":
            self._remediation_cooldown[
                incident["anomaly"]["service"]
            ] = time.time()
        return incident

    def record_feedback(self, incident_id: str, correct: bool, actual_cause: str = None) -> dict:
        incident = next(
            (i for i in self.incidents if i["id"] == incident_id), None
        )
        if not incident:
            return {"error": f"incident {incident_id} not found"}
        self.feedback_store.record(
            incident_id=incident_id,
            rca=incident["rca"],
            correct=correct,
            actual_cause=actual_cause
        )
        incident["feedback"] = {"correct": correct, "actual_cause": actual_cause}
        return incident

    def get_incidents(self, limit: int = 20) -> list:
        return self.incidents[:limit]

    def get_stats(self) -> dict:
        total      = len(self.incidents)
        remediated = sum(1 for i in self.incidents if i["status"] == "remediated")
        pending    = sum(1 for i in self.incidents if i["status"] == "pending_approval")
        failed     = sum(1 for i in self.incidents if i["status"] == "execution_failed")
        feedback   = self.feedback_store.accuracy_stats()
        return {
            "total_incidents": total,
            "remediated":      remediated,
            "pending":         pending,
            "failed":          failed,
            "feedback":        feedback
        }
