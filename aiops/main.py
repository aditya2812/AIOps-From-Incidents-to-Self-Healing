import asyncio
import subprocess
import time
from fastapi import FastAPI, BackgroundTasks, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
from orchestrator import Orchestrator
from config import API_HOST, API_PORT

app        = FastAPI(title="AIOps Agent API")
orchestrator = Orchestrator()

# ── CORS — allow React dashboard to call this API ──────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Request models ─────────────────────────────────────────────────────
class FeedbackRequest(BaseModel):
    correct:      bool
    actual_cause: Optional[str] = None

class ChaosRequest(BaseModel):
    scenario: str   # "oom" | "crash" | "slow"
    service:  str   # "cartservice" | "frontend" etc

# ── Alertmanager webhook ───────────────────────────────────────────────
@app.post("/webhook")
async def alertmanager_webhook(payload: dict, background_tasks: BackgroundTasks):
    """
    Alertmanager calls this endpoint when a rule fires.
    We process each alert in the background so Alertmanager
    doesn't time out waiting for Claude API.
    """
    alerts = payload.get("alerts", [])
    print(f"[webhook] received {len(alerts)} alert(s)")

    for alert in alerts:
        # Only process firing alerts — not resolved ones
        if alert.get("status") == "firing":
            background_tasks.add_task(orchestrator.on_alert, alert)

    return {"status": "accepted", "count": len(alerts)}

# ── Incidents API ──────────────────────────────────────────────────────
@app.get("/incidents")
async def get_incidents(limit: int = 20):
    """Dashboard polls this every 2 seconds."""
    return {
        "incidents": orchestrator.get_incidents(limit),
        "stats":     orchestrator.get_stats(),
        "timestamp": time.time()
    }

@app.get("/incidents/{incident_id}")
async def get_incident(incident_id: str):
    incident = next(
        (i for i in orchestrator.incidents if i["id"] == incident_id), None
    )
    if not incident:
        raise HTTPException(status_code=404, detail="Incident not found")
    return incident

# ── Approval API ───────────────────────────────────────────────────────
@app.post("/incidents/{incident_id}/approve")
async def approve_remediation(incident_id: str):
    """Called when engineer clicks Approve on the dashboard."""
    result = orchestrator.approve_remediation(incident_id)
    if "error" in result:
        raise HTTPException(status_code=400, detail=result["error"])
    return result

# ── Feedback API ───────────────────────────────────────────────────────
@app.post("/incidents/{incident_id}/feedback")
async def record_feedback(incident_id: str, body: FeedbackRequest):
    """Called when engineer clicks ✓ or ✗ on the dashboard."""
    result = orchestrator.record_feedback(
        incident_id=incident_id,
        correct=body.correct,
        actual_cause=body.actual_cause
    )
    if "error" in result:
        raise HTTPException(status_code=400, detail=result["error"])
    return result

# ── Chaos API ─────────────────────────────────────────────────────────
@app.post("/chaos/{scenario}")
async def inject_chaos(scenario: str, service: str = "cartservice"):
    """
    Dashboard chaos buttons call this.
    Injects failures into boutique services.
    """
    import time

    # ── Restore ───────────────────────────────────────────────────────
    if scenario == "restore":
        # Suppress recovery alerts for 45s so noise doesn't pollute demo
        orchestrator.suppress_alerts(45)
        cmds = [
            f"kubectl set resources deployment/{service} --limits=memory=128Mi --requests=memory=64Mi -n boutique",
            f"kubectl scale deployment/{service} --replicas=1 -n boutique",
        ]
        for cmd in cmds:
            subprocess.run(cmd.split(), capture_output=True, timeout=15)
        return {
            "scenario": "restore", "service": service,
            "description": f"Restored {service} to healthy state",
            "command": cmds[0], "status": "success", "stdout": "", "stderr": ""
        }

    # ── OOM — stress the RUNNING pod ──────────────────────────────────
    if scenario == "oom":
        # Cancel suppression window — we want alerts now
        orchestrator._suppress_until = 0
        print("[chaos] suppression window cleared for OOM injection")
        # Step 1: set low memory limit on deployment
        set_cmd = (
            f"kubectl set resources deployment/{service} "
            f"--limits=memory=30Mi --requests=memory=20Mi -n boutique"
        )
        r1 = subprocess.run(set_cmd.split(), capture_output=True, text=True, timeout=15)

        # Step 2: get the currently running pod name
        time.sleep(3)
        get_pod = subprocess.run(
            ["kubectl", "get", "pod", "-n", "boutique",
             "-l", f"app={service}",
             "--field-selector=status.phase=Running",
             "-o", "jsonpath={.items[0].metadata.name}"],
            capture_output=True, text=True, timeout=10
        )
        pod_name = get_pod.stdout.strip()

        # Step 3: exec into pod and allocate 200MB to trigger OOMKill
        if pod_name:
            stress_cmd = [
                "kubectl", "exec", "-n", "boutique", pod_name, "--",
                "sh", "-c",
                "python3 -c 'import time; x=[bytearray(1024*1024) for _ in range(200)]; time.sleep(60)' &"
            ]
            subprocess.run(stress_cmd, capture_output=True, timeout=10)

        return {
            "scenario": "oom", "service": service,
            "description": f"Memory limit 30Mi + 200MB stress injected into {pod_name}",
            "command": set_cmd,
            "status": "success" if r1.returncode == 0 else "failed",
            "stdout": r1.stdout.strip(), "stderr": r1.stderr.strip()
        }

    # ── Crash ──────────────────────────────────────────────────────────
    if scenario == "crash":
        orchestrator._suppress_until = 0
        cmd = f"kubectl delete pod -n boutique -l app={service} --force --grace-period=0"
        result = subprocess.run(cmd.split(), capture_output=True, text=True, timeout=15)
        return {
            "scenario": "crash", "service": service,
            "description": f"Force deleted {service} pod — will restart",
            "command": cmd,
            "status": "success" if result.returncode == 0 else "failed",
            "stdout": result.stdout.strip(), "stderr": result.stderr.strip()
        }

    # ── Slow (scale to zero) ───────────────────────────────────────────
    if scenario == "slow":
        orchestrator._suppress_until = 0
        cmd = f"kubectl scale deployment/{service} --replicas=0 -n boutique"
        result = subprocess.run(cmd.split(), capture_output=True, text=True, timeout=15)
        return {
            "scenario": "slow", "service": service,
            "description": f"Scaled {service} to 0 — downstream calls will time out",
            "command": cmd,
            "status": "success" if result.returncode == 0 else "failed",
            "stdout": result.stdout.strip(), "stderr": result.stderr.strip()
        }

    raise HTTPException(status_code=400, detail="Unknown scenario. Choose from: oom, crash, slow, restore")
@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": time.time()}

@app.get("/graph")
async def get_graph():
    """Returns dependency graph for the dashboard service map."""
    from orchestrator import DEP_GRAPH
    return DEP_GRAPH

@app.get("/feedback/recent")
async def get_recent_feedback():
    return orchestrator.feedback_store.get_recent(10)

@app.post("/reset")
async def reset_incidents():
    """Clear all incidents and feedback — use between demo scenarios."""
    import redis as redis_lib
    orchestrator.incidents = []
    orchestrator._recent_alerts = {}
    orchestrator._remediation_cooldown = {}
    orchestrator._suppress_until = 0
    # Also clear Redis feedback so dashboard shows clean state
    try:
        r = redis_lib.Redis(host="localhost", port=6379, decode_responses=True)
        r.flushall()
    except Exception as e:
        print(f"Redis clear failed: {e}")
    return {"status": "cleared"}

# ── Start server ───────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=API_HOST, port=API_PORT)
