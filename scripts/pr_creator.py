import os, requests

def create_pr(repo, branch):
    url = f"https://api.github.com/repos/{repo}/pulls"
    headers = {"Authorization": f"Bearer {os.environ['GH_PAT']}"}
    payload = {
        "title": "Automated Migration to GitHub Actions",
        "head": branch,
        "base": "master",
        "body": "Migration generated automatically."
    }
    requests.post(url, headers=headers, json=payload)