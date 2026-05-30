# AIOps-From-Incidents-to-Self-Healing

AIOps system built on Kubernetes that automatically detects, diagnoses, and remediates production incidents. The system reads real signals (pod status, metrics, logs, dependency graph) and asks Claude to reason across all of them simultaneously to produce a specific, explainable diagnosis.

The goal was to show what separates AIOps from alert automation — not just detecting that something broke, but understanding why, explaining it in plain English, and proposing the correct fix rather than a generic restart.

## Demo scenario
The demo runs a single scenario live on stage: an OOM kill caused by a misconfigured memory limit — the same failure mode that happens when a developer ships a deployment with resource limits that are too low for the service's actual requirements.

```
Normal state — all services green, pipeline idle

↓ Press "Inject OOM" button

Memory limit set to 30Mi on cartservice
200MB stress injected into the running pod
Pod OOMKilled by the Linux kernel (exit code 137)
CrashLoopBackOff begins

↓ ~30 seconds later

Alertmanager fires: BoutiquePodOOMKilled
Webhook hits the orchestrator
Anomaly agent confirms the signal is genuine
RCA agent calls Claude with:
  - Pod status: last_terminated_reason = OOMKilled, exit 137
  - Memory limit: 30Mi (far below normal operating requirement)
  - Recent logs: normal cart operations before termination
  - Dependency graph: frontend and checkoutservice are upstream callers

Claude responds:
  "Container was killed by the Linux OOM killer due to
   exceeding memory limits. The pod has restarted 3 times
   and will continue to be killed until the memory limit
   is increased. Confidence: 95%"

Remediation proposed:
  kubectl set resources deployment/cartservice
    --limits=memory=512Mi --requests=memory=256Mi

Engineer clicks Approve → kubectl executes → cartservice recovers
Engineer clicks ✓ Correct → feedback stored
```
## Architecture
<img width="1440" height="1560" alt="image" src="https://github.com/user-attachments/assets/6f992642-229f-4288-ad7c-7eb1b6d6bf92" />

## AIOps agents

`Orchestrator` — sequences all four agents in order and handles the operational concerns: deduplication so the same alert doesn't trigger two RCA calls, cooldown windows so a recovering service isn't immediately re-diagnosed, suppression windows after a restore, and a REST API that the dashboard polls every 2 seconds.

`Anomaly agent` — sits between Alertmanager and the rest of the pipeline. Fetches 60 minutes of metric history from Prometheus, computes a Z-score against the baseline, and drops anything below 80% confidence. Prevents noisy alerts from triggering expensive Claude API calls.

`RCA agent` — the core intelligence. Assembles pod status, metrics, logs, dependency graph, and past corrections into a single prompt and calls Claude to reason across all of them simultaneously. Returns a structured diagnosis: root cause, confidence score, affected services, recommended action, and a plain-English explanation for the dashboard.

`Remediation agent` — a decision table, not ML. Maps Claude's recommended_action to a hardcoded kubectl runbook. Safe actions like pod restarts execute automatically; risky changes like memory limit increases require human approval. The AI decides what to do — humans decide what runs without asking.

`Feedback store` — stores engineer verdicts (correct/wrong) in Redis after each incident. When the same service triggers again, past wrong diagnoses are injected into the RCA prompt as context so Claude avoids repeating the same mistake. In-context learning with no model retraining required.

## Workflow
<img width="1440" height="1720" alt="image" src="https://github.com/user-attachments/assets/cb4eade5-49b4-41d1-aa56-6a8fb85c8e47" />
