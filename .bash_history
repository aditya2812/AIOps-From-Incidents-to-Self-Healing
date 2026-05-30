        resp = await http.get(
            'http://localhost:3100/loki/api/v1/query_range',
            params={
                'query': '{app=\"cartservice\"}',
                'start': str(start_ns),
                'end':   str(end_ns),
                'limit': 50
            },
            timeout=10
        )
        streams = resp.json().get('data',{}).get('result',[])
        lines = []
        for s in streams:
            for _, line in s.get('values',[]):
                lines.append(line)
        print(f'Total log lines: {len(lines)}')
        print('--- Last 10 lines ---')
        for l in lines[-10:]:
            print(l[:120])

asyncio.run(check())
"
curl -s 'http://localhost:32002/api/v2/alerts' | python3 -c "
import sys,json
alerts=json.load(sys.stdin)
boutique=[a for a in alerts if 'boutique' in str(a['labels'])]
print(f'Boutique alerts firing: {len(boutique)}')
for a in boutique:
    print(f'  alert: {a[\"labels\"][\"alertname\"]}')
    print(f'  pod:   {a[\"labels\"].get(\"pod\",\"?\")}')
    print(f'  state: {a[\"status\"][\"state\"]}')
    print()
"
kubectl describe pod -n boutique -l app=cartservice | grep -A10 "Last State\|OOM\|Reason\|Exit Code\|Limits"
kubectl get events -n boutique   --field-selector involvedObject.name=cartservice-7cdb9896c5-fdtzp   --sort-by='.lastTimestamp' | tail -10
kubectl get events -n boutique -o json   | python3 -c "
import sys,json
events = json.load(sys.stdin)['items']
cart_events = [
    e for e in events
    if 'cartservice' in e.get('involvedObject',{}).get('name','')
]
for e in sorted(cart_events, key=lambda x: x.get('lastTimestamp',''))[-5:]:
    print(f\"type:    {e['type']}\")
    print(f\"reason:  {e['reason']}\")
    print(f\"message: {e['message']}\")
    print(f\"time:    {e['lastTimestamp']}\")
    print()
"
kubectl get events -n boutique -o json   | python3 -c "
import sys,json
events = json.load(sys.stdin)['items']
cart_events = [
    e for e in events
    if 'cartservice' in e.get('involvedObject',{}).get('name','')
    and e.get('lastTimestamp')  # skip events with null timestamp
]
for e in sorted(cart_events, key=lambda x: x.get('lastTimestamp',''))[-8:]:
    print(f\"type:    {e['type']}\")
    print(f\"reason:  {e['reason']}\")
    print(f\"message: {e['message'][:120]}\")
    print(f\"time:    {e['lastTimestamp']}\")
    print()
"
# This is the cleanest OOM signal — pod container status
kubectl get pod -n boutique -l app=cartservice -o json   | python3 -c "
import sys,json
pods = json.load(sys.stdin)['items']
for pod in pods:
    name = pod['metadata']['name']
    for cs in pod['status'].get('containerStatuses',[]):
        last = cs.get('lastState',{}).get('terminated',{})
        curr = cs.get('state',{})
        print(f'pod:          {name}')
        print(f'restarts:     {cs.get(\"restartCount\",0)}')
        print(f'last_reason:  {last.get(\"reason\",\"none\")}')
        print(f'last_exit:    {last.get(\"exitCode\",\"none\")}')
        print(f'last_message: {last.get(\"message\",\"none\")}')
        print(f'curr_state:   {list(curr.keys())}')
        print()
"
cat <<'PYEOF' > /tmp/fix_rca_pod_status.py
content = open('/home/ec2-user/aiops/agents/rca.py').read()

# Add fetch_pod_status method after fetch_service_metrics
old = '''    def format_metrics(self, metrics: dict) -> str:'''

new = '''    async def fetch_pod_status(self, namespace: str, service: str) -> str:
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

                    curr_state = "running" if "running" in curr else \
                                 "terminated" if "terminated" in curr else \
                                 "waiting" if "waiting" in curr else "unknown"
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

            return "\\n".join(lines) if lines else "No pod status available"
        except Exception as e:
            return f"Could not fetch pod status: {e}"

    def format_metrics(self, metrics: dict) -> str:'''

if old in content:
    open('/home/ec2-user/aiops/agents/rca.py', 'w').write(content.replace(old, new))
    print("✅ fetch_pod_status added")
else:
    print("❌ not found")
PYEOF

python3 /tmp/fix_rca_pod_status.py
# Check if imports exist
head -8 ~/aiops/agents/rca.py
# Add missing imports
sed -i 's/^import httpx/import httpx\nimport subprocess/' ~/aiops/agents/rca.py
echo "✅ subprocess imported"
cat <<'PYEOF' > /tmp/fix_rca_wire_podstatus.py
content = open('/home/ec2-user/aiops/agents/rca.py').read()

# Wire into analyze method
old = '''        # Gather all context in parallel
        error_logs   = await self.fetch_error_logs(anomaly.service)
        recent_logs  = await self.fetch_recent_logs(anomaly.service)
        metrics_raw  = await self.fetch_service_metrics(anomaly.service, anomaly.pod)
        metrics_str  = self.format_metrics(metrics_raw)'''

new = '''        # Gather all context in parallel
        error_logs   = await self.fetch_error_logs(anomaly.service)
        recent_logs  = await self.fetch_recent_logs(anomaly.service)
        metrics_raw  = await self.fetch_service_metrics(anomaly.service, anomaly.pod)
        metrics_str  = self.format_metrics(metrics_raw)
        pod_status   = await self.fetch_pod_status("boutique", anomaly.service)'''

if old in content:
    content = content.replace(old, new)
    print("✅ fetch_pod_status wired into analyze()")
else:
    print("❌ analyze wiring not found")

# Wire into build_prompt call
old2 = '''        prompt = self.build_prompt(
            anomaly, error_logs, recent_logs,
            metrics_str, dep_graph, past_corrections, alert_hint
        )'''

new2 = '''        prompt = self.build_prompt(
            anomaly, error_logs, recent_logs,
            metrics_str, dep_graph, past_corrections,
            alert_hint, pod_status
        )'''

if old2 in content:
    content = content.replace(old2, new2)
    print("✅ pod_status passed to build_prompt()")
else:
    print("❌ build_prompt call not found")

open('/home/ec2-user/aiops/agents/rca.py', 'w').write(content)
PYEOF

python3 /tmp/fix_rca_wire_podstatus.py
cat <<'PYEOF' > /tmp/fix_rca_prompt_podstatus.py
content = open('/home/ec2-user/aiops/agents/rca.py').read()

old = '''    def build_prompt(
        self,
        anomaly:          Anomaly,
        error_logs:       str,
        recent_logs:      str,
        metrics:          str,
        dep_graph:        dict,
        past_corrections: str,
        alert_hint:       str = ""
    ) -> str:'''

new = '''    def build_prompt(
        self,
        anomaly:          Anomaly,
        error_logs:       str,
        recent_logs:      str,
        metrics:          str,
        dep_graph:        dict,
        past_corrections: str,
        alert_hint:       str = "",
        pod_status:       str = ""
    ) -> str:'''

content = content.replace(old, new)

# Add pod_status section to the prompt body
old2 = '''## Error logs (last 5 minutes)
{error_logs}

## Recent logs (last 5 minutes)
{recent_logs}'''

new2 = '''## Pod container status (from Kubernetes API — most reliable OOM signal)
{pod_status}

## Error logs (last 5 minutes)
{error_logs}

## Recent logs (last 5 minutes)
{recent_logs}'''

content = content.replace(old2, new2)
open('/home/ec2-user/aiops/agents/rca.py', 'w').write(content)
print("✅ pod_status added to prompt template")
PYEOF

python3 /tmp/fix_rca_prompt_podstatus.py
cd ~/aiops
python3 -c "
import asyncio
from agents.rca import RCAAgent

agent = RCAAgent()

async def test():
    # Test pod status fetch
    status = await agent.fetch_pod_status('boutique', 'cartservice')
    print('Pod status:')
    print(status)

asyncio.run(test())
"
clear
# Restart server
pkill -f "python3 main.py"
sleep 2
cd ~/aiops
nohup python3 main.py > /tmp/aiops.log 2>&1 &
sleep 3
# Reset incidents
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])"
# Restore cartservice first
curl -s -X POST "http://localhost:8000/chaos/restore?service=cartservice"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])"
echo "Waiting 50s for recovery + suppression..."
sleep 50
kubectl get pods -n boutique | grep cart
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {d[\"stats\"][\"total_incidents\"]} — {\"✅\" if d[\"stats\"][\"total_incidents\"]==0 else \"❌\"}')"
# Restart server
pkill -f "python3 main.py"
sleep 2
cd ~/aiops
nohup python3 main.py > /tmp/aiops.log 2>&1 &
sleep 3
# Reset incidents
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])"
# Restore cartservice first
curl -s -X POST "http://localhost:8000/chaos/restore?service=cartservice"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])"
echo "Waiting 50s for recovery + suppression..."
sleep 50
kubectl get pods -n boutique | grep cart
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {d[\"stats\"][\"total_incidents\"]} — {\"✅\" if d[\"stats\"][\"total_incidents\"]==0 else \"❌\"}')"
# Clear log and inject OOM
> /tmp/aiops.log
curl -s -X POST "http://localhost:8000/chaos/oom?service=cartservice"   | python3 -m json.tool
# Watch pipeline
tail -f /tmp/aiops.log
clear
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc = d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
INC_ID=$(curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['incidents'][0]['id'])
")
echo "Approving: $INC_ID"
curl -s -X POST "http://localhost:8000/incidents/$INC_ID/approve"   | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f'status:  {d[\"status\"]}')
print(f'kubectl: {d[\"execution\"][\"stdout\"]}')
"
# Verify cartservice recovers
sleep 10
kubectl get pods -n boutique | grep cart
ls
cd agents
ls
cat rca.py 
ls
cat anomaly.py 
clear
# 1. Reset all incidents
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin))"
# 2. Restore cartservice
curl -s -X POST "http://localhost:8000/chaos/restore?service=cartservice"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])"
sleep 20
kubectl get pods -n boutique | grep cart
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin))"
grep -n "reset" ~/aiops/main.py
pkill -f "python3 main.py"
sleep 2
cd ~/aiops
nohup python3 main.py > /tmp/aiops.log 2>&1 &
sleep 3
# Test reset
curl -s -X POST http://localhost:8000/reset | python3 -m json.tool
# Restore cartservice
curl -s -X POST "http://localhost:8000/chaos/restore?service=cartservice"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])"
sleep 50
# Confirm clean
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {d[\"stats\"][\"total_incidents\"]} — {\"✅\" if d[\"stats\"][\"total_incidents\"]==0 else \"❌\"}')"
kubectl get pods -n boutique | grep cart
# Kill everything
pkill -f "python3 main.py"
pkill -f "uvicorn"
sleep 2
# Make absolutely sure we're in the right directory
cd /home/ec2-user/aiops
pwd
# Verify main.py has the reset endpoint
grep -n "reset\|def inject_chaos\|def alertmanager" main.py | head -10
# Start from correct directory explicitly
nohup python3 /home/ec2-user/aiops/main.py > /tmp/aiops.log 2>&1 &
sleep 3
# Test
curl -s -X POST http://localhost:8000/reset | python3 -m json.tool
curl -s http://localhost:8000/openapi.json | python3 -c "
import sys,json
spec = json.load(sys.stdin)
for path in spec['paths'].keys():
    print(path)
"
tail -30 ~/aiops/main.py
python3 << 'PYEOF'
content = open('/home/ec2-user/aiops/main.py').read()

old = '''# ── Start server ───────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=API_HOST, port=API_PORT)

@app.post("/reset")
async def reset_incidents():
    """Clear all incidents — use between demo scenarios."""
    orchestrator.incidents = []
    orchestrator._recent_alerts = {}
    orchestrator._remediation_cooldown = {}
    orchestrator._suppress_until = 0
    return {"status": "cleared"}'''

new = '''@app.post("/reset")
async def reset_incidents():
    """Clear all incidents — use between demo scenarios."""
    orchestrator.incidents = []
    orchestrator._recent_alerts = {}
    orchestrator._remediation_cooldown = {}
    orchestrator._suppress_until = 0
    return {"status": "cleared"}

# ── Start server ───────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=API_HOST, port=API_PORT)'''

if old in content:
    open('/home/ec2-user/aiops/main.py', 'w').write(content.replace(old, new))
    print("✅ /reset moved before server start")
else:
    print("❌ not found")
PYEOF

pkill -f "python3 main.py"
sleep 2
cd /home/ec2-user/aiops
nohup python3 main.py > /tmp/aiops.log 2>&1 &
sleep 3
curl -s -X POST http://localhost:8000/reset | python3 -m json.tool
cat /tmp/aiops.log
clear
# Kill whatever is on port 8000
kill $(lsof -t -i:8000) 2>/dev/null
sleep 3
# Verify port is free
ss -tlnp | grep 8000
# Start fresh
cd /home/ec2-user/aiops
nohup python3 main.py > /tmp/aiops.log 2>&1 &
sleep 3
# Verify reset endpoint exists
curl -s http://localhost:8000/openapi.json | python3 -c "
import sys,json
paths=json.load(sys.stdin)['paths']
print('✅ /reset found' if '/reset' in paths else '❌ /reset missing')
print('All routes:', list(paths.keys()))
"
# Test reset
curl -s -X POST http://localhost:8000/reset | python3 -m json.tool
clear
# Restore cartservice
curl -s -X POST "http://localhost:8000/chaos/restore?service=cartservice"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])"
echo "Waiting 50s..."
sleep 50
kubectl get pods -n boutique | grep cart
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {d[\"stats\"][\"total_incidents\"]} — {\"✅\" if d[\"stats\"][\"total_incidents\"]==0 else \"❌\"}')"
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
# Clear log
> /tmp/aiops.log
# Inject OOM
curl -s -X POST "http://localhost:8000/chaos/oom?service=cartservice"   | python3 -m json.tool
# Watch pipeline
tail -f /tmp/aiops.log
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
tail -f /tmp/aiops.log
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
cat <<'PYEOF' > /tmp/fix_dashboard_fetch.py
content = open('/home/ec2-user/aiops-dashboard/src/App.js').read()

old = '''  const fetchData = useCallback(async () => {
    try {
      const [incRes, fbRes] = await Promise.all([
        axios.get(`${API}/incidents`),
        axios.get(`${API}/feedback/recent`),
      ]);
      setIncidents(incRes.data.incidents || []);
      setStats(incRes.data.stats || {});
      setFeedback(fbRes.data || []);
      const active = (incRes.data.incidents || []).find(
        (i) => i.status === "pending_approval"
      );
      if (active) setActiveInc(active);
      else if (!activeInc && incRes.data.incidents?.length > 0)
        setActiveInc(incRes.data.incidents[0]);
    } catch (e) {
      console.error("API error:", e.message);
    }
  }, [activeInc]);

  useEffect(() => {
    fetchData();
    const t = setInterval(fetchData, 2000);
    return () => clearInterval(t);
  }, [fetchData]);'''

new = '''  const fetchData = useCallback(async () => {
    try {
      const [incRes, fbRes] = await Promise.all([
        axios.get(`${API}/incidents`),
        axios.get(`${API}/feedback/recent`),
      ]);
      const newIncidents = incRes.data.incidents || [];
      setIncidents(newIncidents);
      setStats(incRes.data.stats || {});
      setFeedback(fbRes.data || []);

      // Always sync activeInc with latest data from backend
      // This prevents stale incidents showing on frontend
      setActiveInc(prev => {
        // If there is a pending approval — always show it
        const pending = newIncidents.find(i => i.status === "pending_approval");
        if (pending) return pending;
        // If current activeInc still exists in new data — keep it updated
        if (prev) {
          const updated = newIncidents.find(i => i.id === prev.id);
          if (updated) return updated;
        }
        // Default to most recent
        return newIncidents.length > 0 ? newIncidents[0] : null;
      });
    } catch (e) {
      console.error("API error:", e.message);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const t = setInterval(fetchData, 2000);
    return () => clearInterval(t);
  }, [fetchData]);'''

if old in content:
    open('/home/ec2-user/aiops-dashboard/src/App.js', 'w').write(content.replace(old, new))
    print("✅ fetchData fixed — no more stale state")
else:
    print("❌ not found")
PYEOF

python3 /tmp/fix_dashboard_fetch.py
cd ~/aiops-dashboard
npm run build 2>&1 | tail -3
kill $(lsof -t -i:3000) 2>/dev/null
sleep 1
cd ~/aiops-dashboard/build
python3 -c "
import http.server
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control','no-store')
        super().end_headers()
    def log_message(self,*a): pass
http.server.HTTPServer(('0.0.0.0',3000),H).serve_forever()
" &
sleep 2
echo "✅ Dashboard rebuilt"
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin))"
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {d[\"stats\"][\"total_incidents\"]}')
print(f'Feedback:  {d[\"stats\"][\"feedback\"][\"total\"]}')
"
cat <<'PYEOF' > /tmp/fix_reset.py
content = open('/home/ec2-user/aiops/main.py').read()

old = '''@app.post("/reset")
async def reset_incidents():
    """Clear all incidents — use between demo scenarios."""
    orchestrator.incidents = []
    orchestrator._recent_alerts = {}
    orchestrator._remediation_cooldown = {}
    orchestrator._suppress_until = 0
    return {"status": "cleared"}'''

new = '''@app.post("/reset")
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
    return {"status": "cleared"}'''

if old in content:
    open('/home/ec2-user/aiops/main.py', 'w').write(content.replace(old, new))
    print("✅ reset now clears Redis too")
else:
    print("❌ not found")
PYEOF

python3 /tmp/fix_reset.py
kill $(lsof -t -i:8000) 2>/dev/null
sleep 2
cd /home/ec2-user/aiops
nohup python3 main.py > /tmp/aiops.log 2>&1 &
sleep 3
# Full reset including Redis
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin))"
# Verify everything is clean
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {d[\"stats\"][\"total_incidents\"]}')
print(f'Feedback:  {d[\"stats\"][\"feedback\"][\"total\"]}')
"
curl -s http://localhost:8000/feedback/recent | python3 -m json.tool
ls
ls /tmp
cat /tmp/aiops.log 
> /tmp/aiops.log 
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Total: {len(d[\"incidents\"])}')
for inc in d['incidents']:
    print(f'  {inc[\"alertname\"]} | {inc[\"status\"]} | {inc[\"rca\"][\"root_cause\"][:60]}')
"
grep -n "ALLOWED_ALERTS\|skipping\|BoutiquePodRestarting" ~/aiops/orchestrator.py | head -20
python3 << 'PYEOF'
content = open('/home/ec2-user/aiops/orchestrator.py').read()

# Find and show the exact lines around the skip block
idx = content.find("skipping generic alert")
print("Current block:")
print(content[idx-200:idx+300])
PYEOF

python3 << 'PYEOF'
content = open('/home/ec2-user/aiops/orchestrator.py').read()

old = '''        # BoutiquePodOOMKilled and BoutiquePodRestarting tell the real story
        if alertname == "BoutiquePodNotReady":
            print(f"[orchestrator] skipping generic alert: {alertname}")
            return None'''

new = '''        # Only process OOMKilled — most specific signal for our demo
        # BoutiquePodRestarting and BoutiquePodNotReady are too generic
        ALLOWED = {"BoutiquePodOOMKilled", "BoutiqueHighMemory"}
        if alertname not in ALLOWED:
            print(f"[orchestrator] skipping {alertname} — not in allowed list")
            return None'''

if old in content:
    open('/home/ec2-user/aiops/orchestrator.py', 'w').write(content.replace(old, new))
    print("✅ fixed")
else:
    print("❌ still not found — exact string mismatch")
    # Show character by character around the block
    idx = content.find("BoutiquePodNotReady")
    print(repr(content[idx-100:idx+100]))
PYEOF

ls
cd agents/
ls
tail -f /tmp/aiops.log 
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json
d=json.load(sys.stdin)
inc=d['incidents'][0]
print(f'alert:      {inc[\"alertname\"]}')
print(f'root_cause: {inc[\"rca\"][\"root_cause\"]}')
print(f'confidence: {inc[\"rca\"][\"confidence\"]}%')
print(f'action:     {inc[\"proposal\"][\"action\"]}')
print(f'auto:       {inc[\"proposal\"][\"auto_approve\"]}')
print(f'status:     {inc[\"status\"]}')
print()
print(f'reasoning:')
print(f'{inc[\"rca\"][\"reasoning\"]}')
"
sed -n '55,75p' ~/aiops/orchestrator.py
sed -n '85,115p' ~/aiops/orchestrator.py
# Kill everything on port 8000 forcefully
kill -9 $(lsof -t -i:8000) 2>/dev/null
sleep 3
# Verify nothing on 8000
ss -tlnp | grep 8000
# Start fresh
cd /home/ec2-user/aiops
python3 main.py &
sleep 3
# Confirm the filter is working
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin))"
# Test — send a fake BoutiquePodRestarting webhook
curl -s -X POST http://localhost:8000/webhook   -H "Content-Type: application/json"   -d '{"alerts": [{"status": "firing", "labels": {"alertname": "BoutiquePodRestarting", "namespace": "boutique", "pod": "cartservice-test-123"}, "annotations": {}}]}'   | python3 -m json.tool
# Check logs — should show "skipping BoutiquePodRestarting"
sleep 2
grep "skipping\|allowed" /tmp/aiops.log | tail -5
# Kill foreground process
kill $(lsof -t -i:8000) 2>/dev/null
sleep 2
# Clean log and start properly
> /tmp/aiops.log
cd /home/ec2-user/aiops
nohup python3 main.py >> /tmp/aiops.log 2>&1 &
sleep 3
curl -s http://localhost:8000/health
# Reset everything
curl -s -X POST http://localhost:8000/reset   | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])"
# Restore cartservice
curl -s -X POST "http://localhost:8000/chaos/restore?service=cartservice"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])"
echo "Waiting 50s..."
sleep 50
kubectl get pods -n boutique | grep cart
curl -s http://localhost:8000/incidents | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {d[\"stats\"][\"total_incidents\"]} — {\"✅\" if d[\"stats\"][\"total_incidents\"]==0 else \"❌\"}')"
tail -f /tmp/aiops.log 
cat <<'PYEOF' > /tmp/fix_stage5.py
content = open('/home/ec2-user/aiops-dashboard/src/App.js').read()

# Fix stage 5 state — remediation stage should be "active" 
# when pending_approval, not keep showing "thinking..."
old = '''      { icon: "🔧", name: "5 · Remediation",
        state: isRemediated ? "done" : isActive ? "active" : "pending",
        body:  inc.proposal ? {
          action:       inc.proposal.action,
          auto_approve: inc.proposal.auto_approve,
          status:       inc.status,
          id:           inc.id,
        } : null },'''

new = '''      { icon: "🔧", name: "5 · Remediation",
        state: isRemediated ? "done" : (isActive || inc.status === "pending_approval") ? "active" : "pending",
        body:  inc.proposal ? {
          action:       inc.proposal.action,
          auto_approve: inc.proposal.auto_approve,
          status:       inc.status,
          id:           inc.id,
        } : null },'''

if old in content:
    content = content.replace(old, new)
    print("✅ stage 5 state fixed")
else:
    print("❌ stage 5 not found")

# Fix feedback buttons — only show AFTER RCA is done, 
# hide the approve button when feedback is being recorded
old2 = '''                      {(stage.body.status === "remediated" || stage.body.status === "pending_approval") &&
                        activeInc && !activeInc.feedback && (
                        <div style={{ display: "flex", gap: "6px", marginTop: "8px" }}>
                          <button
                            style={{ ...S.approveBtn, background: "#0f2d1f", color: "#4ade80", flex: 1 }}
                            onClick={() => recordFeedback(stage.body.id, true)}
                          >✓ Correct</button>
                          <button
                            style={{ ...S.approveBtn, background: "#3d1515", color: "#f87171", flex: 1, borderColor: "#7f1d1d" }}
                            onClick={() => recordFeedback(stage.body.id, false)}
                          >✗ Wrong</button>
                        </div>
                      )}
                      {activeInc?.feedback && (
                        <div style={{ marginTop: "8px", fontSize: "11px", color: "#475569" }}>
                          Feedback recorded — {activeInc.feedback.correct ? "✓ correct" : "✗ incorrect"}
                        </div>
                      )}'''

new2 = '''                      {/* Feedback buttons — show after remediation or for pending */}
                      {activeInc && !activeInc.feedback && (
                        <div style={{ display: "flex", gap: "6px", marginTop: "8px" }}>
                          <button
                            style={{ ...S.approveBtn, background: "#0f2d1f", color: "#4ade80", flex: 1 }}
                            onClick={() => recordFeedback(activeInc.id, true)}
                          >✓ Correct diagnosis</button>
                          <button
                            style={{ ...S.approveBtn, background: "#3d1515", color: "#f87171", flex: 1, borderColor: "#7f1d1d" }}
                            onClick={() => recordFeedback(activeInc.id, false)}
                          >✗ Wrong diagnosis</button>
                        </div>
                      )}
                      {activeInc?.feedback && (
                        <div style={{ marginTop: "8px", padding: "6px 8px", borderRadius: "6px",
                          background: activeInc.feedback.correct ? "#0f2d1f" : "#3d1515",
                          color: activeInc.feedback.correct ? "#4ade80" : "#f87171",
                          fontSize: "12px", fontWeight: 500 }}>
                          {activeInc.feedback.correct ? "✓ Diagnosis marked correct" : "✗ Diagnosis marked wrong"}
                          {" — feedback stored in learning loop"}
                        </div>
                      )}'''

if old2 in content:
    content = content.replace(old2, new2)
    print("✅ feedback buttons fixed")
else:
    print("❌ feedback buttons not found")

open('/home/ec2-user/aiops-dashboard/src/App.js', 'w').write(content)
PYEOF

python3 /tmp/fix_stage5.py
cd ~/aiops-dashboard
npm run build 2>&1 | tail -3
kill $(lsof -t -i:3000) 2>/dev/null
sleep 1
cd ~/aiops-dashboard/build
python3 -c "
import http.server
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control','no-store')
        super().end_headers()
    def log_message(self,*a): pass
http.server.HTTPServer(('0.0.0.0',3000),H).serve_forever()
" &
sleep 2
echo "✅ rebuilt"
tail -f /tmp/aiops.log 
curl -s -X POST "http://localhost:8000/chaos/oom?service=cartservice"   | python3 -m json.tool
tail -20 /tmp/aiops.log | grep -E "chaos|error|Error"
grep "const API" ~/aiops-dashboard/src/App.js
# Watch the server log in real time and click the button
tail -f /tmp/aiops.log | grep -E "chaos|POST|GET /chaos"
# Watch the server log in real time and click the button
tail -f /tmp/aiops.log | grep -E "chaos|POST|GET /chaos"
 # Watch the server log in real time and click the button
tail -f /tmp/aiops.log | grep -E "chaos|POST|GET /chaos"
INFO:     10.42.0.88:48854 - "POST /webhook HTTP/1.1" 200 OK
# Kill dashboard server
kill $(lsof -t -i:3000) 2>/dev/null
sleep 1
# Verify the source has only OOM and Restore buttons
grep -A2 "chaosBtn\|Inject OOM\|Crash loop\|Scale to zero\|Restore"   ~/aiops-dashboard/src/App.js | grep -v "^--$" | head -20
cat <<'PYEOF' > /tmp/fix_btns_final.py
content = open('/home/ec2-user/aiops-dashboard/src/App.js').read()

# Find current chaos buttons section and replace entirely
import re

old = re.search(
    r'\{\s*key: "oom".*?\.map\(\(\{ key, label, color \}\) => \(',
    content, re.DOTALL
)

if old:
    print("Found buttons block:")
    print(old.group()[:200])
else:
    print("Not found via regex — searching manually")
    idx = content.find('key: "oom"')
    print(content[idx-50:idx+400])
PYEOF

python3 /tmp/fix_btns_final.py
python3 << 'PYEOF'
content = open('/home/ec2-user/aiops-dashboard/src/App.js').read()

old = '''          { key: "oom",     label: "💧 Memory leak (OOM)", color: "#f87171" },
            { key: "crash",   label: "💥 Crash loop",        color: "#fb923c" },
            { key: "slow",    label: "🐢 Scale to zero",     color: "#fbbf24" },
            { key: "restore", label: "🔄 Restore",           color: "#4ade80" },'''

new = '''          { key: "oom",     label: "💧 Inject OOM — memory limit too low", color: "#f87171" },
            { key: "restore", label: "🔄 Restore cartservice",                   color: "#4ade80" },'''

if old in content:
    open('/home/ec2-user/aiops-dashboard/src/App.js', 'w').write(content.replace(old, new))
    print("✅ buttons fixed")
else:
    print("❌ exact string not found — trying with different spacing")
    # Show exact characters
    idx = content.find('key: "crash"')
    print(repr(content[idx-100:idx+200]))
PYEOF

cd ~/aiops-dashboard
npm run build 2>&1 | tail -3
cd ~/aiops-dashboard/build
python3 -c "
import http.server
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control','no-store')
        super().end_headers()
    def log_message(self,*a): pass
http.server.HTTPServer(('0.0.0.0',3000),H).serve_forever()
" &
sleep 2
echo "✅ Dashboard rebuilt — hard refresh browser"
tail -f /tmp/aiops.log | grep -E "chaos|POST|GET /chaos"
cd ~/aiops-dashboard
npm run build 2>&1 | tail -3
cd ~/aiops-dashboard/build
python3 -c "
import http.server
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control','no-store')
        super().end_headers()
    def log_message(self,*a): pass
http.server.HTTPServer(('0.0.0.0',3000),H).serve_forever()
" &
sleep 2
echo "✅ Dashboard rebuilt — hard refresh browser"
kill $(lsof -t -i:3000) 2>/dev/null
sleep 2
cd ~/aiops-dashboard/build
python3 -c "
import http.server
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control','no-store')
        super().end_headers()
    def log_message(self,*a): pass
http.server.HTTPServer(('0.0.0.0',3000),H).serve_forever()
" &
sleep 2
echo "✅ serving on :3000"
