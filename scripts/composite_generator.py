import yaml
from pathlib import Path

def generate_composite(repo_base):

    action = {
        "name": "Composite Action",
        "description": "Generated composite action",
        "runs": {
            "using": "composite",
            "steps": [
                {"run": "echo Running composite action", "shell": "bash"}
            ]
        }
    }

    path = repo_base / ".github/actions/generated/action.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(action, sort_keys=False))