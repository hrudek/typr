#!/usr/bin/env python3
"""Trusted controller: merge a checked same-repository PR, then dispatch main CI.

No PR code runs here. GITHUB_TOKEN merges suppress push workflows, so dispatch
explicitly (an exception to that suppression), including on a controller retry.
"""
import json
import os
import re
import subprocess
from urllib.parse import quote

REQUIRED = {'Linux checks', 'Typr review'}


def api(endpoint, method='GET', **fields):
    command = ['gh', 'api', '--method', method,
               f'repos/{os.environ["GH_REPO"]}/{endpoint}']
    for key, value in fields.items():
        command.extend(['-f', f'{key}={value}'])
    output = subprocess.check_output(command, text=True)
    return json.loads(output) if output.strip() else None


def eligible(pr, repo, branch, sha):
    return (pr['base']['ref'] == 'main' and pr['base']['repo']['full_name'] == repo
            and (pr['head'].get('repo') or {}).get('full_name') == repo
            and pr['head']['ref'] == branch and pr['head']['sha'] == sha
            and not pr['draft']
            and 'no-auto-merge' not in {label['name'] for label in pr['labels']})


def checks_pass(number):
    result = subprocess.run(
        ['gh', 'pr', 'checks', str(number), '--required', '--json', 'name,state'],
        text=True, capture_output=True)
    if result.returncode:
        return False
    checks = json.loads(result.stdout)
    passing = {check['name'] for check in checks if check['state'] == 'SUCCESS'}
    return REQUIRED <= passing and all(
        check['state'] in ('SUCCESS', 'SKIPPED', 'NEUTRAL') for check in checks)


def dispatch(pr):
    merge_sha = pr['merge_commit_sha']
    # Two workflow_run events may observe the same merge. Do not dispatch twice;
    # an existing failed CI is deliberately left to the normal retry/repair flow.
    parent = None
    for workflow in ('typr-checks.yml', 'typr-simulator.yml', 'typr-ci.yml'):
        runs = api(f'actions/workflows/{workflow}/runs?head_sha={merge_sha}&per_page=100')
        if any(run['event'] in ('push', 'workflow_dispatch') for run in runs['workflow_runs']):
            continue
        command = ['gh', 'workflow', 'run', workflow, '--ref', 'main']
        if workflow != 'typr-checks.yml':
            if parent is None:
                parent = api(f'git/commits/{merge_sha}')['parents'][0]['sha']
            command += ['-f', 'distribution=automatic', '-f', f'base_sha={parent}']
        subprocess.run(command, check=True)
        print(f'Dispatched {workflow} after PR #{pr["number"]}.')


def main():
    repo, branch, sha = (os.environ[key] for key in ('GH_REPO', 'SOURCE_BRANCH', 'SOURCE_SHA'))
    if os.environ.get('SOURCE_EVENT') == 'pull_request_target':
        # Do not depend on target-event head metadata naming the PR branch.
        # The reviewed PR/SHA are explicitly pinned in main's trusted run-name.
        match = re.fullmatch(r'Typr review · PR #([1-9][0-9]*) · ([0-9a-f]{40})',
                             os.environ.get('SOURCE_TITLE', ''))
        if not match:
            raise ValueError('Expected a trusted review run-name with PR number and reviewed SHA')
        sha = match[2]
        prs = [api(f'pulls/{match[1]}')]
        branch = prs[0]['head']['ref']
    else:
        owner = repo.split('/')[0]
        # Include merged PRs so a rerun can recover a failed dispatch.
        prs = api(f'pulls?state=all&base=main&head={quote(owner + ":" + branch, safe="")}&per_page=100')
    for candidate in prs:
        if not eligible(candidate, repo, branch, sha):
            continue
        pr = api(f'pulls/{candidate["number"]}')
        if not eligible(pr, repo, branch, sha):
            continue
        if pr['state'] == 'open':
            if not checks_pass(pr['number']):
                print('Required checks are not all green; leaving PR open.')
                return
            # Server-side SHA pin rejects a push racing with the check/merge.
            result = api(f'pulls/{pr["number"]}/merge', 'PUT', sha=sha, merge_method='squash')
            if not result.get('merged'):
                raise RuntimeError('GitHub did not merge the PR')
            pr = api(f'pulls/{pr["number"]}')
        if pr.get('merged') and (pr.get('merged_by') or {}).get('login') == 'github-actions[bot]':
            dispatch(pr)
        return
    print('No current, ready same-repository PR for this run.')


if __name__ == '__main__':
    main()
