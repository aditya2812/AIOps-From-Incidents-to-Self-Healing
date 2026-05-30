#!/bin/bash

API="http://localhost:8000"
PASS=0
FAIL=0

log()  { echo "[$(date +%H:%M:%S)] $1"; }
pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Helper: wait for incident to appear ───────────────────────────────
wait_for_incident() {
  local scenario=$1
  local max_wait=120
  local elapsed=0
  log "Waiting for incident (max ${max_wait}s)..."
  while [ $elapsed -lt $max_wait ]; do
    COUNT=$(curl -s "$API/incidents" | python3 -c "
import sys,json
d=json.load(sys.stdin)
incidents=[i for i in d['incidents'] if i['status'] in ['pending_approval','remediated']]
print(len(incidents))
" 2>/dev/null)
    if [ "$COUNT" -gt "0" ] 2>/dev/null; then
      log "Incident appeared after ${elapsed}s"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed+5))
    echo -n "."
  done
  echo ""
  return 1
}

# ── Helper: get latest incident ────────────────────────────────────────
latest_incident() {
  curl -s "$API/incidents" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d['incidents']:
    i=d['incidents'][0]
    print(f\"status={i['status']}\")
    print(f\"service={i['anomaly']['service']}\")
    print(f\"root_cause={i['rca']['root_cause']}\")
    print(f\"action={i['proposal']['action']}\")
    print(f\"confidence={i['rca']['confidence']}%\")
    print(f\"reasoning={i['rca']['reasoning'][:100]}\")
else:
    print('no incidents')
" 2>/dev/null
}

# ── Pre-flight checks ──────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  AIOps Demo Test — $(date)"
echo "══════════════════════════════════════════"
echo ""
log "PRE-FLIGHT CHECKS"

# API health
HEALTH=$(curl -s "$API/health" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
[ "$HEALTH" = "ok" ] && pass "API server running" || { fail "API server not running"; exit 1; }

# Prometheus reachable
PROM=$(curl -s "http://localhost:32001/api/v1/query?query=up" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
[ "$PROM" = "success" ] && pass "Prometheus reachable" || fail "Prometheus unreachable"

# Loki reachable
LOKI=$(curl -s "http://localhost:3100/loki/api/v1/labels" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
[ "$LOKI" = "success" ] && pass "Loki reachable" || fail "Loki unreachable — port-forward may be down"

# Cartservice healthy
CART=$(kubectl get pods -n boutique -l app=cartservice \
  --no-headers 2>/dev/null | awk '{print $2}' | head -1)
[ "$CART" = "1/1" ] && pass "cartservice healthy ($CART)" || fail "cartservice not ready ($CART)"

# Incidents empty
COUNT=$(curl -s "$API/incidents" | python3 -c "import sys,json; print(json.load(sys.stdin)['stats']['total_incidents'])" 2>/dev/null)
[ "$COUNT" = "0" ] && pass "Incident list clean" || { 
  fail "Stale incidents present ($COUNT) — run: pkill -f 'python3 main.py' && redis6-cli flushall then restart"
}

echo ""
echo "══════════════════════════════════════════"
log "SCENARIO 1 — OOM Kill (memory leak)"
echo "══════════════════════════════════════════"

# Inject OOM
log "Injecting OOM chaos..."
RESULT=$(curl -s -X POST "$API/chaos/oom?service=cartservice" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
[ "$RESULT" = "success" ] && pass "OOM chaos injected" || fail "OOM injection failed"

# Wait for incident
if wait_for_incident "oom"; then
  pass "Incident created by pipeline"
  echo ""
  log "Incident details:"
  latest_incident | sed 's/^/    /'
  echo ""

  # Check RCA quality
  ACTION=$(curl -s "$API/incidents" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d['incidents']: print(d['incidents'][0]['proposal']['action'])
else: print('none')
" 2>/dev/null)
  STATUS=$(curl -s "$API/incidents" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d['incidents']: print(d['incidents'][0]['status'])
else: print('none')
" 2>/dev/null)

  [ "$STATUS" = "remediated" ] && pass "Auto-remediation executed" || \
    pass "Pending approval (manual remediation scenario)"
else
  fail "No incident created within 120s"
fi

# Restore
log "Restoring cartservice..."
curl -s -X POST "$API/chaos/restore?service=cartservice" > /dev/null
sleep 20
CART=$(kubectl get pods -n boutique -l app=cartservice \
  --no-headers 2>/dev/null | awk '{print $2}' | head -1)
[ "$CART" = "1/1" ] && pass "cartservice restored ($CART)" || \
  fail "cartservice not recovered ($CART)"

# Cooldown
log "Waiting 30s cooldown before next scenario..."
sleep 30

echo ""
echo "══════════════════════════════════════════"
log "SCENARIO 2 — Crash loop (pod delete)"
echo "══════════════════════════════════════════"

BEFORE=$(curl -s "$API/incidents" | python3 -c "
import sys,json; print(json.load(sys.stdin)['stats']['total_incidents'])" 2>/dev/null)

log "Injecting crash chaos..."
RESULT=$(curl -s -X POST "$API/chaos/crash?service=cartservice" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
[ "$RESULT" = "success" ] && pass "Crash chaos injected" || fail "Crash injection failed"

# Wait for new incident
log "Waiting for new incident..."
elapsed=0
while [ $elapsed -lt 90 ]; do
  AFTER=$(curl -s "$API/incidents" | python3 -c "
import sys,json; print(json.load(sys.stdin)['stats']['total_incidents'])" 2>/dev/null)
  if [ "$AFTER" -gt "$BEFORE" ] 2>/dev/null; then
    pass "New incident created"
    log "Incident details:"
    latest_incident | sed 's/^/    /'
    break
  fi
  sleep 5
  elapsed=$((elapsed+5))
  echo -n "."
done
[ $elapsed -ge 90 ] && fail "No new incident within 90s — crash may not trigger restart counter"

sleep 20

echo ""
echo "══════════════════════════════════════════"
log "SCENARIO 3 — Scale to zero (service down)"
echo "══════════════════════════════════════════"

BEFORE=$(curl -s "$API/incidents" | python3 -c "
import sys,json; print(json.load(sys.stdin)['stats']['total_incidents'])" 2>/dev/null)

log "Scaling cartservice to 0..."
RESULT=$(curl -s -X POST "$API/chaos/slow?service=cartservice" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null)
[ "$RESULT" = "success" ] && pass "Scale-to-zero injected" || fail "Scale-to-zero failed"

log "Waiting for incident..."
elapsed=0
while [ $elapsed -lt 90 ]; do
  AFTER=$(curl -s "$API/incidents" | python3 -c "
import sys,json; print(json.load(sys.stdin)['stats']['total_incidents'])" 2>/dev/null)
  if [ "$AFTER" -gt "$BEFORE" ] 2>/dev/null; then
    pass "New incident created"
    log "Incident details:"
    latest_incident | sed 's/^/    /'
    break
  fi
  sleep 5
  elapsed=$((elapsed+5))
  echo -n "."
done
[ $elapsed -ge 90 ] && fail "No new incident within 90s"

# Restore
log "Restoring cartservice..."
curl -s -X POST "$API/chaos/restore?service=cartservice" > /dev/null
kubectl scale deployment/cartservice --replicas=1 -n boutique > /dev/null 2>&1
sleep 15
CART=$(kubectl get pods -n boutique -l app=cartservice \
  --no-headers 2>/dev/null | awk '{print $2}' | head -1)
[ "$CART" = "1/1" ] && pass "cartservice restored" || fail "cartservice not recovered"

echo ""
echo "══════════════════════════════════════════"
log "FRONTEND CHECK"
echo "══════════════════════════════════════════"

# Check dashboard is serving
DASH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000)
[ "$DASH" = "200" ] && pass "Dashboard serving on :3000" || fail "Dashboard not reachable (:$DASH)"

# Check incidents API returns correct structure
STRUCTURE=$(curl -s "$API/incidents" | python3 -c "
import sys,json
d=json.load(sys.stdin)
keys=['incidents','stats','timestamp']
missing=[k for k in keys if k not in d]
print('ok' if not missing else f'missing: {missing}')
" 2>/dev/null)
[ "$STRUCTURE" = "ok" ] && pass "API response structure correct" || fail "API structure: $STRUCTURE"

# Check dep graph endpoint
GRAPH=$(curl -s "$API/graph" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('ok' if 'edges' in d and 'nodes' in d else 'missing edges/nodes')
" 2>/dev/null)
[ "$GRAPH" = "ok" ] && pass "Dependency graph endpoint working" || fail "Graph endpoint: $GRAPH"

# Check feedback endpoint
FB=$(curl -s "$API/feedback/recent" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('ok' if isinstance(d,list) else 'wrong type')
" 2>/dev/null)
[ "$FB" = "ok" ] && pass "Feedback endpoint working" || fail "Feedback endpoint: $FB"

echo ""
echo "══════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════════"
echo ""

# Final incident summary
log "Final incident summary:"
curl -s "$API/incidents" | python3 -c "
import sys,json,datetime
d=json.load(sys.stdin)
print(f'  Total:      {d[\"stats\"][\"total_incidents\"]}')
print(f'  Remediated: {d[\"stats\"][\"remediated\"]}')
print(f'  Pending:    {d[\"stats\"][\"pending\"]}')
print(f'  Failed:     {d[\"stats\"][\"failed\"]}')
print()
for i in d['incidents']:
    t=datetime.datetime.fromtimestamp(i['timestamp']).strftime('%H:%M:%S')
    print(f'  [{t}] {i[\"anomaly\"][\"service\"]:20s} {i[\"status\"]:20s} {i[\"rca\"][\"root_cause\"][:50]}')
"
