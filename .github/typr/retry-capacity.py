#!/usr/bin/env python3
"""Retry a single unallocated hosted macOS job, never a test/code failure.

Runs from trusted dev only. GitHub run_attempt bounds retries, including
manual reruns. No branch code, signing secret, or agent is used here.
"""
import json
import os
import re
import subprocess
import time
from urllib.parse import quote

WORKFLOWS = {
    '.github/workflows/typr-ci.yml',
    '.github/workflows/typr-simulator.yml',
}
DELAYS = (300, 600, 1200)
HOSTED_MACOS_LABELS = ('macos-', 'xcode-')  # e.g. macos-26, xcode-27
CAPACITY_ERROR = 'The job was not acquired by Runner of type hosted even after multiple attempts'


def api(repo, endpoint, method='GET'):
    result = subprocess.check_output(
        ['gh', 'api', '--method', method, f'repos/{repo}/{endpoint}'], text=True)
    return json.loads(result) if result.strip() else None


def pages(repo, endpoint, key=None):
    items = []
    for page in range(1, 101):
        separator = '&' if '?' in endpoint else '?'
        result = api(repo, f'{endpoint}{separator}per_page=100&page={page}')
        batch = result[key] if key else result
        items.extend(batch)
        if len(batch) < 100:
            return items
    raise ValueError('Too many API results; refusing an incomplete check')


def eligible_run(run, repo):
    return (
        run['repository']['full_name'] == repo
        and (run.get('head_repository') or {}).get('full_name') == repo
        and run['path'] in WORKFLOWS
        and run['event'] in ('push', 'workflow_dispatch')
        and run['status'] == 'completed'
        # GitHub capacity loss produces a failed run with a cancelled job.
        # A user-cancelled run must stay cancelled.
        and run['conclusion'] == 'failure'
        and 1 <= run['run_attempt'] <= len(DELAYS)
    )


def eligible_job(job, annotations):
    return (
        job['conclusion'] in ('cancelled', 'failure')
        and job.get('runner_id', 0) == 0
        and not job.get('steps')
        and any(label.startswith(HOSTED_MACOS_LABELS) for label in job.get('labels', []))
        and any(item.get('annotation_level') == 'failure'
                and item.get('message', '').strip() == CAPACITY_ERROR for item in annotations)
    )


def current_source(repo, run):
    branch = quote(run['head_branch'], safe='')
    try:
        current = api(repo, f'branches/{branch}')
    except subprocess.CalledProcessError:
        return False  # Deleted/inaccessible branch: never revive an obsolete run.
    return current['commit']['sha'] == run['head_sha']


def report(message):
    print(message)
    if os.getenv('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(message + '\n')


def retry(repo, run_id):
    run = api(repo, f'actions/runs/{run_id}')
    if not eligible_run(run, repo):
        report('No capacity retry: unrelated run, not failed, or retry budget exhausted.')
        return
    if not current_source(repo, run):
        report('No capacity retry: branch moved or was deleted.')
        return
    jobs = pages(repo, f'actions/runs/{run_id}/jobs?filter=latest', 'jobs')
    candidate = None
    for job in jobs:
        # Do not even fetch annotations for jobs which executed code.
        if job.get('runner_id', 0) or job.get('steps'):
            continue
        annotations = pages(repo, f'check-runs/{job["id"]}/annotations')
        if eligible_job(job, annotations):
            candidate = job
            break
    if candidate is None:
        report('No capacity retry: no unallocated hosted macOS job with the exact capacity error.')
        return
    delay = DELAYS[run['run_attempt'] - 1]
    report(f'Runner unavailable for {candidate["name"]}; retry {run["run_attempt"]}/3 in {delay // 60} minutes.')
    time.sleep(delay)
    # Another retry, manual intervention, push or merge during the wait wins.
    current = api(repo, f'actions/runs/{run_id}')
    if (not eligible_run(current, repo) or current['run_attempt'] != run['run_attempt']
            or not current_source(repo, current)):
        report('Capacity retry abandoned: run or source changed while waiting.')
        return
    # One job per attempt: never rerun successful builds/signing or real test failures.
    # GitHub also reruns that job's dependent jobs when required.
    api(repo, f'actions/jobs/{candidate["id"]}/rerun', method='POST')
    report(f'Requested capacity retry: {run["html_url"]} (job {candidate["id"]}).')


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    run_id = os.environ['SOURCE_RUN_ID']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
        raise ValueError('Invalid repository')
    if not re.fullmatch(r'[1-9][0-9]*', run_id):
        raise ValueError('Invalid run ID')
    retry(repo, run_id)


if __name__ == '__main__':
    main()
