#!/usr/bin/env python3
"""Rewrite the pinned Typr status issue from GitHub data (gh only). Env: GH_REPO."""
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
from pathlib import Path

TITLE = "Typr status"
MARKER = "<!-- typr-status -->"
WARN_DAYS = 30


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


def gh_json(*args: str):
    out = gh(*args)
    return json.loads(out) if out.strip() else None


def icon(conclusion: str | None, status: str = "completed") -> str:
    if status != "completed":
        return "🔄"
    return {"success": "✅", "failure": "❌", "cancelled": "⏹️", "skipped": "⏭️"}.get(conclusion or "", "❔")


def ago(stamp: str) -> str:
    then = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    minutes = int((dt.datetime.now(dt.timezone.utc) - then).total_seconds() // 60)
    if minutes < 60:
        return f"{minutes} min ago"
    if minutes < 48 * 60:
        return f"{minutes // 60} h ago"
    return f"{minutes // 1440} days ago"


def runs(workflow: str, **filters: str) -> list[dict]:
    args = ["run", "list", "--workflow", workflow, "--limit", "30",
            "--json", "databaseId,status,conclusion,createdAt,event,headBranch,url,displayTitle"]
    for key, value in filters.items():
        args += [f"--{key}", value]
    return gh_json(*args) or []


def last_testflight(repo: str) -> str:
    for run in runs("typr-ci.yml", branch="main"):
        jobs = gh_json("api", f"repos/{repo}/actions/runs/{run['databaseId']}/jobs",
                       "--jq", "[.jobs[] | {name, conclusion}]") or []
        sign = next((j for j in jobs if j["name"].startswith("Sign (testflight")), None)
        if sign and sign["conclusion"] in ("success", "failure"):
            return f"{icon(sign['conclusion'])} [{ago(run['createdAt'])}]({run['url']})"
    return "none in the last 30 release runs"


def red_runs(push: dict | None, label: str = "main CI") -> list[str]:
    """Failed main CI runs the owner fixes locally (no repair agent in CI)."""
    if push and push["status"] == "completed" and push["conclusion"] == "failure":
        return [f"- ❌ [{label} failed]({push['url']}) ({push['displayTitle']}): fix locally on a "
                "`fix/<name>` branch through a PR (`gh run view <id> --log-failed`)"]
    return []


def find_issue():
    # Reuse the existing pinned issue during the rebrand, preserving its number
    # and pin. The old title is only a lookup key, never newly published copy.
    for title in (TITLE, "Hex+ status"):
        issue = next((i for i in gh_json("issue", "list", "--state", "open", "--search",
                                        f'in:title "{title}"', "--json", "number,title,body") or []
                      if i["title"] == title), None)
        if issue:
            return issue
    return None


def main() -> None:
    repo = os.environ["GH_REPO"]
    issue = find_issue()
    lines = [MARKER,
             "_Updated by the Typr status workflow. Nothing here needs you unless it says so._", ""]

    attention: list[str] = []
    human = gh_json("issue", "list", "--state", "open", "--label", "needs-human", "--json", "number,title,url") or []
    for item in human:
        attention.append(f"- 🙋 [#{item['number']} {item['title']}]({item['url']})")
    today = dt.date.today()
    expiries = json.loads((Path(__file__).parent / "expiry.json").read_text())["items"]
    rows = []
    for item in sorted(expiries, key=lambda e: e["expires"]):
        days = (dt.date.fromisoformat(item["expires"]) - today).days
        mark = "🔴" if days <= WARN_DAYS else "🟢"
        approx = " (approx.)" if item.get("approximate") else ""
        rows.append(f"| {mark} {item['name']} | {item['expires']}{approx} | {days} days |")
        if days <= WARN_DAYS:
            attention.append(f"- 🔴 **{item['name']}** expires {item['expires']}: {item['renew']}")

    lanes = {}
    for label, workflow in (("Checks", "typr-checks.yml"),
                            ("Simulator tests", "typr-simulator.yml"),
                            ("TestFlight / device build", "typr-ci.yml")):
        lanes[label] = next((r for r in runs(workflow, branch="main")
                             if r["event"] in ("push", "workflow_dispatch")), None)
        attention += red_runs(lanes[label], label)

    lines += ["### Needs you", *(attention or ["Nothing. ✅"]), ""]

    lines += ["### Pipeline", "| | Last | |", "|---|---|---|"]
    def row(name: str, run: dict | None) -> None:
        if run:
            lines.append(f"| {name} | {icon(run['conclusion'], run['status'])} | [{ago(run['createdAt'])}]({run['url']}) |")
        else:
            lines.append(f"| {name} | – | never |")
    for label, run in lanes.items():
        row(label, run)
    lines.append(f"| TestFlight upload | {last_testflight(repo)} | |")
    lines.append("")

    open_prs = gh_json("pr", "list", "--state", "open", "--json", "number,title,url,labels,isDraft") or []
    lines += ["### Open PRs"]
    lines += [f"- [#{p['number']} {p['title']}]({p['url']})" + (" (draft)" if p["isDraft"] else "") for p in open_prs] or ["None."]
    lines += ["", "### Renewals", "| What | Expires | Left |", "|---|---|---|", *rows, "",
              "<sub>Apple Developer Program membership renews yearly in your Apple account (not tracked here).</sub>"]

    body = "\n".join(lines) + "\n"
    if issue:
        gh("issue", "edit", str(issue["number"]), "--title", TITLE, "--body", body)
    else:
        url = gh("issue", "create", "--title", TITLE, "--body", body).strip()
        print(f"Created {url}; pin it once in the GitHub UI.")
    print(body)


if __name__ == "__main__":
    main()
