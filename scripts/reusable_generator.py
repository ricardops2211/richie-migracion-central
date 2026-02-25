import yaml
from pathlib import Path

def generate_reusable(repo_base):
    reusable = {
        "name": "Reusable CI",
        "on": {"workflow_call": {}},
        "jobs": {
            "build": {
                "runs-on": "ubuntu-latest",
                "steps": [
                    {"uses": "actions/checkout@v4"},
                    {"run": "echo Reusable workflow executed"}
                ]
            }
        }
    }

    path = repo_base / ".github/workflows/_reusable.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.dump(reusable))