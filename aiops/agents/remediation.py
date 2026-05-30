import subprocess
from dataclasses import dataclass
from typing import Optional, Tuple
from config import AUTO_APPROVE_ENABLED

@dataclass
class RemediationProposal:
    action:       str    # human readable — shown on dashboard
    command:      str    # actual kubectl command
    auto_approve: bool   # True = execute immediately, False = wait for human
    risk:         str    # low / medium / high

class RemediationAgent:

    # ── Runbook decision table ──────────────────────────────────────────
    # RCA recommended_action → what to actually run
    # auto_approve is set by YOU, not the LLM.
    # The LLM diagnoses. You decide what runs automatically.
    # ────────────────────────────────────────────────────────────────────
    RUNBOOKS = {
        "restart": {
            "action":       "Rolling restart of {service} deployment",
            "command":      "kubectl rollout restart deployment/{service} -n {namespace}",
            "auto_approve": True,    # safe — rolling restart, zero downtime
            "risk":         "low"
        },
        "scale_up": {
            "action":       "Scale {service} from 1 to 3 replicas",
            "command":      "kubectl scale deployment/{service} --replicas=3 -n {namespace}",
            "auto_approve": True,    # safe — additive change only
            "risk":         "low"
        },
        "increase_memory_limit": {
            "action":       "Increase {service} memory limit to 512Mi",
            "command":      "kubectl set resources deployment/{service} --limits=memory=512Mi --requests=memory=256Mi -n {namespace}",
            "auto_approve": False,   # requires human — changes resource allocation
            "risk":         "medium"
        },
        "notify_only": {
            "action":       "No automated action — human investigation required",
            "command":      None,
            "auto_approve": False,
            "risk":         "high"
        }
    }

    def propose(self, rca: dict, namespace: str = "boutique") -> RemediationProposal:
        """
        Takes RCA output and returns a remediation proposal.
        Looks up the runbook for the recommended action.
        Formats the kubectl command with the actual service name.
        """
        action_key = rca.get("recommended_action", "notify_only")
        runbook    = self.RUNBOOKS.get(action_key, self.RUNBOOKS["notify_only"])

        # Get the primary affected service
        services = rca.get("affected_services", [])
        service  = services[0] if services else "unknown"

        # Format action and command with real service name
        action  = runbook["action"].format(service=service, namespace=namespace)
        command = None
        if runbook["command"]:
            command = runbook["command"].format(service=service, namespace=namespace)

        # Respect global AUTO_APPROVE_ENABLED flag
        # Even if runbook says auto_approve=True, we can disable it globally
        auto_approve = runbook["auto_approve"] and AUTO_APPROVE_ENABLED

        return RemediationProposal(
            action=action,
            command=command,
            auto_approve=auto_approve,
            risk=runbook["risk"]
        )

    def execute(self, proposal: RemediationProposal) -> dict:
        """
        Executes the kubectl command.
        Only called after human approval or if auto_approve=True.
        Returns execution result dict.
        """
        if not proposal.command:
            return {
                "status": "skipped",
                "reason": "notify_only — no command to execute"
            }

        print(f"[remediation] executing: {proposal.command}")

        try:
            result = subprocess.run(
                proposal.command.split(),
                capture_output=True,
                text=True,
                timeout=30
            )
            status = "success" if result.returncode == 0 else "failed"
            print(f"[remediation] {status}: {result.stdout.strip() or result.stderr.strip()}")

            return {
                "status":  status,
                "command": proposal.command,
                "stdout":  result.stdout.strip(),
                "stderr":  result.stderr.strip(),
                "returncode": result.returncode
            }

        except subprocess.TimeoutExpired:
            return {
                "status":  "timeout",
                "command": proposal.command,
                "stdout":  "",
                "stderr":  "kubectl command timed out after 30s"
            }
        except Exception as e:
            return {
                "status":  "error",
                "command": proposal.command,
                "stdout":  "",
                "stderr":  str(e)
            }

    def dry_run(self, proposal: RemediationProposal) -> dict:
        """
        Validates the remediation proposal by checking the target
        deployment exists. kubectl rollout restart does not support
        --dry-run so we verify the deployment instead.
        """
        if not proposal.command:
            return {"status": "skipped", "reason": "notify_only"}

        # Extract deployment name and namespace from command
        # e.g. kubectl rollout restart deployment/cartservice -n boutique
        try:
            parts     = proposal.command.split()
            namespace = "boutique"
            service   = None

            for i, p in enumerate(parts):
                if p == "-n" and i + 1 < len(parts):
                    namespace = parts[i + 1]
                if p.startswith("deployment/"):
                    service = p.split("/")[1]

            if not service:
                return {"status": "skipped", "reason": "could not parse deployment name"}

            # Check deployment exists
            check_cmd = f"kubectl get deployment {service} -n {namespace}"
            print(f"[remediation] dry-run check: {check_cmd}")

            result = subprocess.run(
                check_cmd.split(),
                capture_output=True,
                text=True,
                timeout=10
            )
            return {
                "status":  "valid" if result.returncode == 0 else "invalid",
                "command": proposal.command,
                "stdout":  result.stdout.strip(),
                "stderr":  result.stderr.strip()
            }
        except Exception as e:
            return {"status": "error", "stderr": str(e)}

# Patch dry_run method - rollout restart doesn't support --dry-run
# Instead we verify the deployment exists
