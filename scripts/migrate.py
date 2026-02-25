import os, re, json, yaml, requests, sys
from pathlib import Path
from reusable_generator import generate_reusable
from composite_generator import generate_composite
from pr_creator import create_pr

SOURCE = Path("../source")
ARTIFACTS = Path("artifacts")

REPO = os.environ["REPO_NAME"]
BRANCH = os.environ["BRANCH_NAME"]
TYPE = os.environ["TYPE"]
SHARED_PATHS = json.loads(os.environ.get("SHARED_LIB_PATHS", "[]"))

def analyze_jenkins():
    jf = SOURCE / os.environ.get("JENKINS_PATH", "Jenkinsfile")
    if not jf.exists():
        return {}

    content = jf.read_text(errors="ignore")

    return {
        "stages": len(re.findall(r"stage\s*\(", content)),
        "parallel": len(re.findall(r"parallel\s*{", content)),
        "matrix": len(re.findall(r"matrix\s*{", content)),
        "uses_docker": "docker" in content.lower(),
        "uses_credentials": "withCredentials" in content
    }

def analyze_shared():
    total = 0
    for path in SHARED_PATHS:
        p = SOURCE / path
        if p.exists():
            total += len(list(p.rglob("*.groovy")))
    return {"files": total}

def classify(j, s):
    score = j.get("stages",0) + j.get("parallel",0)*2 + s.get("files",0)
    if score < 5: return "simple"
    if score < 15: return "multi-stage"
    if score < 30: return "enterprise"
    return "shared-lib-heavy"

def save_metadata(meta):
    base = ARTIFACTS / REPO.replace("/", "-") / BRANCH
    base.mkdir(parents=True, exist_ok=True)
    (base / "metadata.json").write_text(json.dumps(meta, indent=2))
    return base

def main():
    j = analyze_jenkins()
    s = analyze_shared()
    classification = classify(j, s)

    metadata = {
        "repo": REPO,
        "branch": BRANCH,
        "classification": classification,
        "jenkins": j,
        "shared": s
    }

    repo_base = save_metadata(metadata)

    if classification in ["enterprise", "shared-lib-heavy"]:
        generate_reusable(repo_base)

    if s["files"] > 3:
        generate_composite(repo_base)

    if os.environ.get("AUTO_PR") == "true":
        create_pr(REPO, BRANCH)

if __name__ == "__main__":
    main()