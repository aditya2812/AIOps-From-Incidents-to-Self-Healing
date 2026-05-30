import { useState, useEffect, useCallback } from "react";
import axios from "axios";

const API = "http://100.53.16.255:8000";

const S = {
  app: {
    fontFamily: "system-ui, -apple-system, sans-serif",
    background: "#0f1117",
    minHeight: "100vh",
    color: "#e2e8f0",
    fontSize: "13px",
  },
  topbar: {
    background: "#1a1d27",
    borderBottom: "1px solid #2d3148",
    padding: "10px 20px",
    display: "flex",
    alignItems: "center",
    gap: "12px",
  },
  title: { fontSize: "15px", fontWeight: 600, color: "#fff" },
  badge: (color) => ({
    fontSize: "11px", padding: "2px 10px",
    borderRadius: "10px", fontWeight: 500,
    background: color === "red" ? "#3d1515" : color === "green" ? "#0f2d1f" : "#1e1b3a",
    color: color === "red" ? "#f87171" : color === "green" ? "#4ade80" : "#a5b4fc",
    border: `1px solid ${color === "red" ? "#7f1d1d" : color === "green" ? "#14532d" : "#312e81"}`,
  }),
  layout: {
    display: "grid",
    gridTemplateColumns: "160px 1fr 240px 180px",
    gap: "10px",
    padding: "10px",
    height: "calc(100vh - 45px)",
  },
  panel: {
    background: "#1a1d27",
    border: "1px solid #2d3148",
    borderRadius: "10px",
    padding: "12px",
    overflow: "auto",
  },
  panelTitle: {
    fontSize: "11px", fontWeight: 600,
    color: "#64748b", textTransform: "uppercase",
    letterSpacing: "0.05em", marginBottom: "10px",
  },
  svc: (status) => ({
    display: "flex", alignItems: "center", gap: "8px",
    padding: "5px 7px", borderRadius: "6px", marginBottom: "3px",
    background: status === "ok" ? "#0f2d1f22" : status === "warn" ? "#2d1a0022" : "#3d151522",
    border: `1px solid ${status === "ok" ? "#14532d44" : status === "warn" ? "#92400e44" : "#7f1d1d44"}`,
  }),
  dot: (status) => ({
    width: "7px", height: "7px", borderRadius: "50%", flexShrink: 0,
    background: status === "ok" ? "#4ade80" : status === "warn" ? "#fbbf24" : "#f87171",
    boxShadow: `0 0 6px ${status === "ok" ? "#4ade80" : status === "warn" ? "#fbbf24" : "#f87171"}`,
  }),
  metricRow: {
    display: "flex", justifyContent: "space-between",
    padding: "4px 0", borderBottom: "1px solid #2d314822", fontSize: "12px",
  },
  stage: (state) => ({
    border: `1px solid ${state === "active" ? "#6366f1" : state === "done" ? "#14532d" : "#2d3148"}`,
    borderRadius: "8px", marginBottom: "8px",
    opacity: state === "pending" ? 0.4 : 1,
    transition: "all 0.3s",
  }),
  stageHeader: (state) => ({
    display: "flex", alignItems: "center", gap: "8px",
    padding: "8px 10px",
    background: state === "active" ? "#1e1b3a" : state === "done" ? "#0f2d1f22" : "#1a1d27",
    borderRadius: state === "pending" ? "8px" : "8px 8px 0 0",
  }),
  stageBody: {
    padding: "8px 10px", borderTop: "1px solid #2d3148",
    fontSize: "12px", color: "#94a3b8", lineHeight: 1.6,
  },
  stateBadge: (state) => ({
    marginLeft: "auto", fontSize: "10px", padding: "1px 7px",
    borderRadius: "8px", fontWeight: 500,
    background: state === "active" ? "#1e1b3a" : state === "done" ? "#0f2d1f" : "#1a1d2744",
    color: state === "active" ? "#a5b4fc" : state === "done" ? "#4ade80" : "#475569",
    border: `1px solid ${state === "active" ? "#6366f1" : state === "done" ? "#14532d" : "#2d3148"}`,
  }),
  rcaBox: {
    background: "#0f1117", borderRadius: "6px",
    padding: "8px 10px", marginTop: "6px",
  },
  rcaLabel: { fontSize: "10px", color: "#475569", textTransform: "uppercase", letterSpacing: "0.04em" },
  rcaVal:   { fontSize: "13px", fontWeight: 500, color: "#e2e8f0", marginTop: "2px" },
  confBar:  { height: "3px", background: "#2d3148", borderRadius: "2px", marginTop: "6px", overflow: "hidden" },
  confFill: (pct) => ({ height: "100%", width: `${pct}%`, background: "#4ade80", borderRadius: "2px" }),
  approveBtn: {
    width: "100%", marginTop: "8px", padding: "7px",
    borderRadius: "6px", background: "#0f2d1f",
    color: "#4ade80", border: "1px solid #14532d",
    fontSize: "12px", fontWeight: 500, cursor: "pointer",
  },
  chaosBtn: (color) => ({
    width: "100%", padding: "6px 8px", borderRadius: "6px",
    marginBottom: "6px", border: `1px solid ${color}44`,
    background: `${color}11`, color: color,
    fontSize: "11px", fontWeight: 500, cursor: "pointer",
    textAlign: "left", display: "flex", alignItems: "center", gap: "6px",
  }),
  fbItem: {
    padding: "6px 8px", borderRadius: "6px",
    border: "1px solid #2d3148", marginBottom: "5px",
    background: "#0f111722", fontSize: "11px",
  },
  fbTag: (correct) => ({
    display: "inline-block", padding: "1px 6px",
    borderRadius: "5px", fontSize: "10px", fontWeight: 500,
    background: correct ? "#0f2d1f" : "#3d1515",
    color: correct ? "#4ade80" : "#f87171", marginTop: "3px",
  }),
};

// ── Dep graph layout ───────────────────────────────────────────────────
const NODES = [
  { id: "frontend",              x: 120, y: 28,  label: "frontend" },
  { id: "checkoutservice",       x: 50,  y: 100, label: "checkout" },
  { id: "cartservice",           x: 140, y: 100, label: "cart" },
  { id: "productcatalogservice", x: 210, y: 100, label: "catalog" },
  { id: "paymentservice",        x: 30,  y: 175, label: "payment" },
  { id: "emailservice",          x: 90,  y: 175, label: "email" },
  { id: "shippingservice",       x: 150, y: 175, label: "shipping" },
  { id: "redis-cart",            x: 140, y: 248, label: "redis-cart" },
  { id: "recommendationservice", x: 210, y: 175, label: "reco" },
  { id: "currencyservice",       x: 50,  y: 248, label: "currency" },
  { id: "adservice",             x: 210, y: 248, label: "adservice" },
];

const EDGES = [
  { from: "frontend",              to: "cartservice" },
  { from: "frontend",              to: "checkoutservice" },
  { from: "frontend",              to: "productcatalogservice" },
  { from: "frontend",              to: "recommendationservice" },
  { from: "frontend",              to: "currencyservice" },
  { from: "frontend",              to: "adservice" },
  { from: "frontend",              to: "shippingservice" },
  { from: "checkoutservice",       to: "cartservice" },
  { from: "checkoutservice",       to: "paymentservice" },
  { from: "checkoutservice",       to: "emailservice" },
  { from: "checkoutservice",       to: "shippingservice" },
  { from: "checkoutservice",       to: "currencyservice" },
  { from: "checkoutservice",       to: "productcatalogservice" },
  { from: "cartservice",           to: "redis-cart" },
  { from: "recommendationservice", to: "productcatalogservice" },
];

function getNodePos(id) {
  return NODES.find((n) => n.id === id) || { x: 0, y: 0 };
}

function nodeStatus(id, affectedServices, incidents) {
  if (affectedServices.includes(id)) return "error";
  // upstream caller of an affected service
  const callsAffected = EDGES.some(
    (e) => e.from === id && affectedServices.includes(e.to)
  );
  if (callsAffected) return "warn";
  // downstream dependency of affected
  const calledByAffected = EDGES.some(
    (e) => e.to === id && affectedServices.includes(e.from)
  );
  if (calledByAffected) return "warn";
  return "ok";
}

function edgeStatus(edge, affectedServices) {
  if (
    affectedServices.includes(edge.from) ||
    affectedServices.includes(edge.to)
  ) return "affected";
  return "ok";
}

// ── Dep graph component ────────────────────────────────────────────────
function DepGraph({ incidents }) {
  const affectedServices = incidents
    .filter((i) => i.status !== "remediated")
    .flatMap((i) => i.rca?.affected_services || [i.anomaly?.service])
    .filter(Boolean);

  const hasIncident = affectedServices.length > 0;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <div style={S.panelTitle}>Dependency graph</div>
      {hasIncident && (
        <div style={{
          fontSize: "10px", color: "#f87171", marginBottom: "6px",
          padding: "3px 8px", background: "#3d151522",
          borderRadius: "5px", border: "1px solid #7f1d1d44"
        }}>
          🔴 blast radius: {affectedServices.join(", ")}
        </div>
      )}
      <svg
        viewBox="0 0 260 290"
        style={{ flex: 1, width: "100%" }}
      >
        {/* Edges */}
        {EDGES.map((edge, i) => {
          const from   = getNodePos(edge.from);
          const to     = getNodePos(edge.to);
          const status = edgeStatus(edge, affectedServices);
          return (
            <line
              key={i}
              x1={from.x} y1={from.y}
              x2={to.x}   y2={to.y}
              stroke={status === "affected" ? "#f87171" : "#2d3148"}
              strokeWidth={status === "affected" ? 1.5 : 1}
              strokeDasharray={status === "affected" ? "4 2" : "none"}
              opacity={status === "affected" ? 0.8 : 0.5}
            />
          );
        })}

        {/* Nodes */}
        {NODES.map((node) => {
          const status = nodeStatus(node.id, affectedServices, incidents);
          const color  = status === "error" ? "#f87171"
                       : status === "warn"  ? "#fbbf24"
                       : "#4ade80";
          const bg     = status === "error" ? "#3d1515"
                       : status === "warn"  ? "#2d1a00"
                       : "#0f2d1f";
          return (
            <g key={node.id}>
              <circle
                cx={node.x} cy={node.y} r="15"
                fill={bg}
                stroke={color}
                strokeWidth={status === "error" ? 2 : 1}
              >
                {status === "error" && (
                  <>
                    <animate attributeName="stroke-width" values="2;3;2" dur="1s" repeatCount="indefinite"/>
                    <animate attributeName="stroke-opacity" values="1;0.4;1" dur="1s" repeatCount="indefinite"/>
                  </>
                )}
              </circle>
              <text
                x={node.x} y={node.y + 1}
                textAnchor="middle"
                dominantBaseline="middle"
                fontSize="6"
                fill={color}
                fontWeight={status === "error" ? "bold" : "normal"}
              >
                {node.label}
              </text>
            </g>
          );
        })}

        {/* Legend */}
        <circle cx="20"  cy="275" r="5" fill="#3d1515" stroke="#f87171" strokeWidth="1.5"/>
        <text x="29"  y="279" fontSize="7" fill="#f87171">affected</text>
        <circle cx="85"  cy="275" r="5" fill="#2d1a00" stroke="#fbbf24" strokeWidth="1.5"/>
        <text x="94"  y="279" fontSize="7" fill="#fbbf24">at risk</text>
        <circle cx="145" cy="275" r="5" fill="#0f2d1f" stroke="#4ade80" strokeWidth="1.5"/>
        <text x="154" y="279" fontSize="7" fill="#4ade80">healthy</text>
      </svg>
    </div>
  );
}

// ── Helpers ────────────────────────────────────────────────────────────
const SERVICES = [
  "frontend","cartservice","checkoutservice","paymentservice",
  "emailservice","shippingservice","currencyservice",
  "productcatalogservice","recommendationservice","adservice","redis-cart",
];

function svcStatus(name, incidents) {
  const active = incidents.find(
    (i) => i.anomaly?.service === name && i.status !== "remediated"
  );
  if (active) return "error";
  const recent = incidents.find(
    (i) => i.anomaly?.service === name &&
           i.status === "remediated" &&
           Date.now() / 1000 - i.timestamp < 120
  );
  return recent ? "warn" : "ok";
}

function Cursor() {
  const [vis, setVis] = useState(true);
  useEffect(() => {
    const t = setInterval(() => setVis((v) => !v), 500);
    return () => clearInterval(t);
  }, []);
  return (
    <span style={{
      display: "inline-block", width: "6px", height: "12px",
      background: vis ? "#a5b4fc" : "transparent",
      verticalAlign: "middle", marginLeft: "2px",
    }}/>
  );
}

// ── Main App ───────────────────────────────────────────────────────────
export default function App() {
  const [incidents,    setIncidents]    = useState([]);
  const [stats,        setStats]        = useState({});
  const [feedback,     setFeedback]     = useState([]);
  const [activeInc,    setActiveInc]    = useState(null);
  const [chaosLoading, setChaosLoading] = useState("");

  const fetchData = useCallback(async () => {
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
  }, [fetchData]);

  async function injectChaos(scenario, service = "cartservice") {
    setChaosLoading(scenario);
    try {
      await axios.post(`${API}/chaos/${scenario}?service=${service}`);
      setTimeout(fetchData, 1000);
    } catch (e) { alert(`Chaos failed: ${e.message}`); }
    finally { setChaosLoading(""); }
  }

  async function resetIncidents() {
    setChaosLoading("reset");
    try {
      await axios.post(`${API}/reset`);
      setActiveInc(null);
      setTimeout(fetchData, 500);
    } catch (e) { alert(`Reset failed: ${e.message}`); }
    finally { setChaosLoading(""); }
  }

  async function approve(incidentId) {
    try {
      await axios.post(`${API}/incidents/${incidentId}/approve`);
      fetchData();
    } catch (e) { alert(`Approve failed: ${e.message}`); }
  }

  async function recordFeedback(incidentId, correct) {
    try {
      await axios.post(`${API}/incidents/${incidentId}/feedback`, { correct });
      fetchData();
    } catch (e) { alert(`Feedback failed: ${e.message}`); }
  }

  const hasActive   = incidents.some((i) => i.status !== "remediated");
  const statusColor = hasActive ? "red" : "green";
  const statusText  = hasActive ? "⚠ Incident Active" : "● All Systems Normal";

  function getPipelineStages(inc) {
    if (!inc) return [
      { icon: "📡", name: "1 · Telemetry ingestion", state: "done",    body: "Collecting metrics, logs and traces from all boutique services." },
      { icon: "📈", name: "2 · Predictive baseline", state: "done",    body: "Baseline established. All services within normal parameters." },
      { icon: "🔍", name: "3 · Anomaly detection",   state: "done",    body: "No anomalies detected. Monitoring continuously." },
      { icon: "🧠", name: "4 · Root cause analysis", state: "pending", body: null },
      { icon: "🔧", name: "5 · Remediation",         state: "pending", body: null },
    ];
    const isActive     = inc.status === "pending_approval";
    const isRemediated = inc.status === "remediated";
    return [
      { icon: "📡", name: "1 · Telemetry ingestion", state: "done",
        body: `Metrics, logs and traces collected from ${inc.anomaly?.service}. Alert: ${inc.alertname}.` },
      { icon: "📈", name: "2 · Predictive baseline", state: "done",
        body: `Baseline: ${inc.anomaly?.baseline_mean?.toFixed(1) ?? "0"} (normal). ` +
              `Current: ${inc.anomaly?.current_value?.toFixed(1) ?? "?"}  —  ` +
              `Z-score ${inc.anomaly?.z_score?.toFixed(1) ?? "?"}.` },
      { icon: "🔍", name: "3 · Anomaly detection", state: "done",
        body: `Anomaly confirmed on ${inc.anomaly?.pod ?? "?"}. ` +
              `Confidence: ${((inc.anomaly?.confidence ?? 0) * 100).toFixed(0)}%.` },
      { icon: "🧠", name: "4 · Root cause analysis",
        state: isActive || isRemediated ? "done" : "active",
        body:  inc.rca ? {
          root_cause: inc.rca.root_cause,
          confidence: inc.rca.confidence,
          reasoning:  inc.rca.reasoning,
          severity:   inc.rca.severity,
        } : null },
      { icon: "🔧", name: "5 · Remediation",
        state: isRemediated ? "done" : (isActive || inc.status === "pending_approval") ? "active" : "pending",
        body:  inc.proposal ? {
          action:       inc.proposal.action,
          auto_approve: inc.proposal.auto_approve,
          status:       inc.status,
          id:           inc.id,
        } : null },
    ];
  }

  const stages = getPipelineStages(activeInc);

  return (
    <div style={S.app}>
      {/* Topbar */}
      <div style={S.topbar}>
        <span style={S.title}>AIOps</span>
        <span style={{ color: "#475569", fontSize: "12px" }}>boutique namespace · k3s</span>
        <span style={S.badge(statusColor)}>{statusText}</span>
        <span style={{ marginLeft: "auto", fontSize: "11px", color: "#475569" }}>
          {stats.total_incidents ?? 0} incidents · {stats.remediated ?? 0} remediated
        </span>
      </div>

      <div style={S.layout}>

        {/* ── Panel 1: Services ── */}
        <div style={S.panel}>
          <div style={S.panelTitle}>Services</div>
          {SERVICES.map((name) => (
            <div key={name} style={S.svc(svcStatus(name, incidents))}>
              <div style={S.dot(svcStatus(name, incidents))}/>
              <span style={{ fontSize: "11px", fontWeight: 500, color: "#e2e8f0" }}>{name}</span>
            </div>
          ))}
          {activeInc && (
            <>
              <div style={{ ...S.panelTitle, marginTop: "12px" }}>
                {activeInc.anomaly?.service}
              </div>
              <div style={S.metricRow}>
                <span style={{ color: "#64748b" }}>z-score</span>
                <span style={{ color: "#f87171", fontWeight: 500 }}>
                  {activeInc.anomaly?.z_score?.toFixed(1) ?? "?"}
                </span>
              </div>
              <div style={S.metricRow}>
                <span style={{ color: "#64748b" }}>confidence</span>
                <span style={{ color: "#4ade80", fontWeight: 500 }}>
                  {((activeInc.anomaly?.confidence ?? 0) * 100).toFixed(0)}%
                </span>
              </div>
              <div style={S.metricRow}>
                <span style={{ color: "#64748b" }}>severity</span>
                <span style={{ color: "#fbbf24", fontWeight: 500 }}>
                  {activeInc.rca?.severity ?? "?"}
                </span>
              </div>
              <div style={S.metricRow}>
                <span style={{ color: "#64748b" }}>status</span>
                <span style={{
                  color: activeInc.status === "remediated" ? "#4ade80" : "#f87171",
                  fontWeight: 500
                }}>
                  {activeInc.status}
                </span>
              </div>
            </>
          )}
        </div>

        {/* ── Panel 2: Pipeline ── */}
        <div style={S.panel}>
          <div style={S.panelTitle}>Reasoning pipeline</div>
          {stages.map((stage, i) => (
            <div key={i} style={S.stage(stage.state)}>
              <div style={S.stageHeader(stage.state)}>
                <span>{stage.icon}</span>
                <span style={{ fontWeight: 500, color: "#e2e8f0" }}>{stage.name}</span>
                <span style={S.stateBadge(stage.state)}>
                  {stage.state === "active" ? "thinking…" : stage.state === "done" ? "done" : "waiting"}
                </span>
              </div>
              {stage.body && stage.state !== "pending" && (
                <div style={S.stageBody}>
                  {i === 3 && typeof stage.body === "object" && (
                    <>
                      <div style={S.rcaBox}>
                        <div style={S.rcaLabel}>Root cause</div>
                        <div style={S.rcaVal}>
                          {stage.body.root_cause}
                          {stage.state === "active" && <Cursor/>}
                        </div>
                        <div style={{ display: "flex", justifyContent: "space-between", marginTop: "6px" }}>
                          <span style={{ color: "#475569", fontSize: "11px" }}>Confidence</span>
                          <span style={{ color: "#4ade80", fontWeight: 500, fontSize: "11px" }}>
                            {stage.body.confidence}%
                          </span>
                        </div>
                        <div style={S.confBar}>
                          <div style={S.confFill(stage.body.confidence)}/>
                        </div>
                      </div>
                      <div style={{ marginTop: "8px", color: "#94a3b8", lineHeight: 1.6 }}>
                        {stage.body.reasoning}
                      </div>
                    </>
                  )}
                  {i === 4 && typeof stage.body === "object" && (
                    <>
                      <div style={{ color: "#94a3b8" }}>
                        Proposed: <span style={{ color: "#e2e8f0", fontWeight: 500 }}>
                          {stage.body.action}
                        </span>
                      </div>
                      {stage.body.status === "pending_approval" && (
                        <button style={S.approveBtn} onClick={() => approve(stage.body.id)}>
                          ▶ Approve remediation
                        </button>
                      )}
                      {stage.body.status === "remediated" && (
                        <div style={{ marginTop: "8px", color: "#4ade80", fontWeight: 500 }}>
                          ✅ Remediation executed successfully
                        </div>
                      )}
                      {/* Feedback buttons — show after remediation or for pending */}
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
                      )}
                    </>
                  )}
                  {typeof stage.body === "string" && <span>{stage.body}</span>}
                </div>
              )}
            </div>
          ))}
          {incidents.length > 0 && (
            <>
              <div style={{ ...S.panelTitle, marginTop: "12px" }}>Recent incidents</div>
              {incidents.slice(0, 5).map((inc) => (
                <div key={inc.id} onClick={() => setActiveInc(inc)} style={{
                  padding: "6px 8px", borderRadius: "6px", marginBottom: "4px", cursor: "pointer",
                  background: activeInc?.id === inc.id ? "#1e1b3a" : "#0f111722",
                  border: `1px solid ${activeInc?.id === inc.id ? "#6366f1" : "#2d3148"}`,
                }}>
                  <div style={{ display: "flex", justifyContent: "space-between" }}>
                    <span style={{ color: "#e2e8f0", fontWeight: 500, fontSize: "12px" }}>
                      {inc.anomaly?.service}
                    </span>
                    <span style={{ fontSize: "10px", color: inc.status === "remediated" ? "#4ade80" : "#f87171" }}>
                      {inc.status}
                    </span>
                  </div>
                  <div style={{ color: "#64748b", fontSize: "11px", marginTop: "2px" }}>
                    {inc.rca?.root_cause?.slice(0, 60)}...
                  </div>
                </div>
              ))}
            </>
          )}
        </div>

        {/* ── Panel 3: Dependency graph ── */}
        <div style={S.panel}>
          <DepGraph incidents={incidents}/>
        </div>

        {/* ── Panel 4: Chaos + Feedback ── */}
        <div style={S.panel}>
          <div style={S.panelTitle}>Chaos injection</div>
          {[
            { key: "oom",     label: "💧 Inject OOM — memory limit too low", color: "#f87171" },
            { key: "restore", label: "🔄 Restore cartservice",                   color: "#4ade80" },
          ].map(({ key, label, color }) => (
            <button
              key={key}
              style={S.chaosBtn(color)}
              onClick={() => injectChaos(key)}
              disabled={chaosLoading === key}
            >
              {chaosLoading === key ? "Running..." : label}
            </button>
          ))}

          <button
            style={{
              width: "100%", padding: "6px 8px", borderRadius: "6px",
              marginTop: "4px", border: "1px solid #6366f144",
              background: "#1e1b3a", color: "#a5b4fc",
              fontSize: "11px", fontWeight: 500, cursor: "pointer",
            }}
            onClick={resetIncidents}
            disabled={chaosLoading === "reset"}
          >
            {chaosLoading === "reset" ? "Clearing..." : "⚡ Reset incidents"}
          </button>

          <div style={{ ...S.panelTitle, marginTop: "14px" }}>AIOps health</div>
          {[
            ["total",      stats.total_incidents ?? 0, "#e2e8f0"],
            ["remediated", stats.remediated ?? 0,      "#4ade80"],
            ["pending",    stats.pending ?? 0,         "#fbbf24"],
            ["accuracy",   `${stats.feedback?.accuracy ?? 0}%`, "#4ade80"],
          ].map(([label, val, color]) => (
            <div key={label} style={S.metricRow}>
              <span style={{ color: "#64748b" }}>{label}</span>
              <span style={{ color, fontWeight: 500 }}>{val}</span>
            </div>
          ))}

          <div style={{ ...S.panelTitle, marginTop: "14px" }}>Feedback loop</div>
          {feedback.length === 0 && (
            <div style={{ color: "#475569", fontSize: "11px" }}>No feedback yet</div>
          )}
          {feedback.slice(0, 4).map((fb, i) => (
            <div key={i} style={S.fbItem}>
              <div style={{ color: "#94a3b8", fontWeight: 500 }}>{fb.service}</div>
              <div style={{ color: "#64748b", marginTop: "1px" }}>
                {fb.root_cause?.slice(0, 45)}...
              </div>
              <span style={S.fbTag(fb.correct)}>
                {fb.correct ? "✓ correct" : "✗ wrong"}
              </span>
            </div>
          ))}
        </div>

      </div>
    </div>
  );
}
