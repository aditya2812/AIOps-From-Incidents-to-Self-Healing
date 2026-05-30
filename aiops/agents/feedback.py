import redis
import json
import time
from config import REDIS_HOST, REDIS_PORT

r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

class FeedbackStore:

    def record(self, incident_id: str, rca: dict, correct: bool, actual_cause: str = None):
        """Engineer clicks ✓ or ✗ on the dashboard."""
        feedback = {
            "incident_id":  incident_id,
            "rca_output":   json.dumps(rca),
            "correct":      str(correct),
            "actual_cause": actual_cause or "",
            "service":      rca.get("affected_services", ["unknown"])[0],
            "timestamp":    str(time.time())
        }
        r.hset(f"feedback:{incident_id}", mapping=feedback)
        r.lpush(f"feedback_history:{feedback['service']}", json.dumps(feedback))
        r.ltrim(f"feedback_history:{feedback['service']}", 0, 19)
        return feedback

    def get_corrections_for_service(self, service: str) -> str:
        """
        Returns past wrong diagnoses injected into the RCA prompt.
        Deduplicates by root_cause so same mistake never appears twice.
        """
        raw = r.lrange(f"feedback_history:{service}", 0, 9)
        if not raw:
            return ""

        seen_causes = set()
        corrections = []

        for item in raw:
            f = json.loads(item)
            if f["correct"] == "False" and f["actual_cause"]:
                rca_out  = json.loads(f["rca_output"])
                diagnosed = rca_out.get("root_cause", "?")

                # Skip if we've already included this root cause
                if diagnosed in seen_causes:
                    continue
                seen_causes.add(diagnosed)

                corrections.append(
                    f"- Previously diagnosed as: '{diagnosed}'\n"
                    f"  Actual cause was: '{f['actual_cause']}'"
                )

        if not corrections:
            return ""

        return (
            "## Past incorrect diagnoses for this service — learn from these\n"
            + "\n".join(corrections)
        )

    def accuracy_stats(self) -> dict:
        keys = r.keys("feedback:*")
        if not keys:
            return {"total": 0, "correct": 0, "wrong": 0, "accuracy": 0.0}
        records  = [r.hgetall(k) for k in keys]
        total    = len(records)
        correct  = sum(1 for rec in records if rec.get("correct") == "True")
        wrong    = total - correct
        accuracy = round((correct / total) * 100, 1) if total else 0.0
        return {"total": total, "correct": correct, "wrong": wrong, "accuracy": accuracy}

    def get_recent(self, limit: int = 5) -> list:
        keys = r.keys("feedback:*")
        if not keys:
            return []
        items = []
        for k in keys:
            rec = r.hgetall(k)
            if rec:
                rca = json.loads(rec.get("rca_output", "{}"))
                items.append({
                    "incident_id":  rec.get("incident_id"),
                    "service":      rec.get("service"),
                    "root_cause":   rca.get("root_cause", "unknown"),
                    "correct":      rec.get("correct") == "True",
                    "actual_cause": rec.get("actual_cause", ""),
                    "timestamp":    float(rec.get("timestamp", 0))
                })
        items.sort(key=lambda x: x["timestamp"], reverse=True)
        return items[:limit]
