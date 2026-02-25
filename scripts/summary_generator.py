import json
from pathlib import Path

ARTIFACTS = Path("artifacts")
summary = {
    "total_repos": 0,
    "simple": 0,
    "multi-stage": 0,
    "enterprise": 0,
    "shared-lib-heavy": 0
}

for meta in ARTIFACTS.rglob("metadata.json"):
    data = json.loads(meta.read_text())
    summary["total_repos"] += 1
    summary[data["classification"]] += 1

(ARTIFACTS / "enterprise-summary.json").write_text(
    json.dumps(summary, indent=2)
)