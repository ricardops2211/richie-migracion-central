import yaml
from pathlib import Path

def generate_composite(repo_base):
    action = {
        "name": "Composite Action",
        "runs": {
            "using": "composite",
            "steps": [
                {"run": "echo Composite action executed", "shell": "bash"}
            ]
        }
    }

    path = repo_base / ".github/actions/composite/action.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.dump(action))