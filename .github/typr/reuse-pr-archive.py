#!/usr/bin/env python3
"""Select and verify an existing PR archive; never run code from the PR.

Runs only from main. GitHub supplies run/job/artifact identity; build.json
must agree with it. Revalidate after environment approval, before downloading.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import zipfile

from config import load


REQUIRED_JOBS = ('Linux checks', 'Decide', 'Unsigned archive')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(repo, endpoint):
    return json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{repo}/{endpoint}'], text=True))


def pages(repo, endpoint, key):
    values = []
    for page in range(1, 101):
        separator = '&' if '?' in endpoint else '?'
        batch = api(repo, f'{endpoint}{separator}per_page=100&page={page}')[key]
        values.extend(batch)
        if len(batch) < 100:
            return values
    raise ValueError('Too many API results; refusing an incomplete check')


def validate_pr(pr, repo):
    require(pr['state'] == 'open' and not pr['draft'], 'PR must be open and ready for review')
    require(pr['base']['repo']['full_name'] == repo and pr['base']['ref'] == 'main',
            'PR must target this repository\'s main branch')
    require(pr['head']['repo'] and pr['head']['repo']['full_name'] == repo,
            'Fork PR archives cannot be signed')
    require(pr['head']['ref'].startswith('feature/'), 'Only feature/* PRs can reuse archives')
    require(re.fullmatch(r'[0-9a-f]{40}', pr['head']['sha']), 'Invalid PR commit')


def validate_run(run, pr, repo):
    require(run['repository']['full_name'] == repo
            and run['head_repository']['full_name'] == repo, 'Run must belong to this repository')
    require(run['event'] == 'workflow_dispatch'
            and run['path'] == '.github/workflows/typr-ci.yml', 'Expected a manually dispatched unsigned build (typr-ci.yml)')
    require(run['head_sha'] == pr['head']['sha'] and run['head_branch'] == pr['head']['ref'],
            'PR changed since this run; wait for CI on the current commit')
    # Tests/screenshots may still run or fail; only the required jobs gate reuse.
    # Never reuse a cancelled run or a run awaiting execution/approval.
    require(run['status'] == 'in_progress'
            or (run['status'] == 'completed' and run['conclusion'] in ('success', 'failure')),
            'CI run must be in progress or completed, not cancelled or awaiting execution')


def validate_jobs(jobs):
    for name in REQUIRED_JOBS:
        matching = [job for job in jobs if job['name'] == name]
        require(len(matching) == 1 and matching[0]['conclusion'] == 'success',
                f'{name} must be successful, not skipped, cancelled or failed')


def validate_artifact(artifacts, run):
    matching = [item for item in artifacts if item['name'] == f'typr-unsigned-{run["id"]}']
    require(len(matching) == 1, 'Expected exactly one unsigned archive artifact')
    artifact = matching[0]
    require(not artifact['expired'], 'Archive expired; manually run Unsigned build (typr-ci.yml) with distribution=unsigned on the PR branch')
    require(artifact['workflow_run']['id'] == run['id']
            and artifact['workflow_run']['head_sha'] == run['head_sha'], 'Artifact run mismatch')
    require(re.fullmatch(r'sha256:[0-9a-f]{64}', artifact.get('digest') or ''),
            'Artifact has no supported GitHub SHA-256 digest; rerun the manual unsigned build')
    return artifact


def validate_metadata(metadata, run, config):
    require(metadata['source_sha'] == run['head_sha'], 'Archive source commit mismatch')
    require(str(metadata['run']) == str(run['id']), 'Archive run mismatch')
    require(metadata['app'] == config, 'Archive identity differs from current Typr identity')
    require(re.fullmatch(r'[0-9a-f]{40}', metadata.get('workflow_sha') or ''),
            'Missing archive workflow commit')


def unpack_artifact(path, destination, artifact, run, config):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    require(f'sha256:{digest.hexdigest()}' == artifact['digest'], 'GitHub artifact SHA-256 mismatch')
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(len(entries) == 2 and {item.filename for item in entries}
                == {'archive.zip.age', 'build.json'}, 'Unexpected artifact files')
        for item in entries:
            require(not stat.S_ISLNK(item.external_attr >> 16), 'Artifact contains a symlink')
        require(archive.getinfo('build.json').file_size <= 65536, 'Archive metadata too large')
        metadata = json.loads(archive.read('build.json'))
        validate_metadata(metadata, run, config)
        destination.mkdir(parents=True, exist_ok=True)
        for name in ('archive.zip.age', 'build.json'):
            with archive.open(name) as source, (destination / name).open('wb') as target:
                shutil.copyfileobj(source, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pr', required=True, type=int)
    parser.add_argument('--run', type=int, help='Revalidate this exact selected run after approval')
    parser.add_argument('--download', type=Path)
    args = parser.parse_args()
    require(args.pr > 0 and (args.run is None or args.run > 0), 'Expected positive IDs')
    repo = os.environ['GITHUB_REPOSITORY']
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo), 'Invalid repository')
    pr = api(repo, f'pulls/{args.pr}')
    validate_pr(pr, repo)
    if args.run:
        run = api(repo, f'actions/runs/{args.run}')
    else:
        runs = pages(repo, 'actions/workflows/typr-ci.yml/runs'
                     f'?event=workflow_dispatch&head_sha={pr["head"]["sha"]}', 'workflow_runs')
        matching = [run for run in runs if run['head_branch'] == pr['head']['ref']]
        require(matching, 'No manual build for the current commit; run Unsigned build (typr-ci.yml) on the PR branch with distribution=unsigned')
        # Never silently fall back to an older run when the latest lacks a passing archive.
        run = max(matching, key=lambda item: item['id'])
    validate_run(run, pr, repo)
    validate_jobs(pages(repo, f'actions/runs/{run["id"]}/jobs?filter=latest', 'jobs'))
    artifact = validate_artifact(pages(repo, f'actions/runs/{run["id"]}/artifacts', 'artifacts'), run)
    if args.download:
        args.download.mkdir(parents=True, exist_ok=True)
        zipped = args.download / 'github-artifact.zip'
        try:
            with zipped.open('wb') as target:
                subprocess.run(['gh', 'api', f'repos/{repo}/actions/artifacts/{artifact["id"]}/zip'],
                               stdout=target, check=True)
            unpack_artifact(zipped, args.download, artifact, run, load())
        finally:
            zipped.unlink(missing_ok=True)
        # A push/close during download must not silently sign the old revision.
        current = api(repo, f'pulls/{args.pr}')
        validate_pr(current, repo)
        validate_run(run, current, repo)
    print(f'PR #{args.pr}: reuse CI run {run["id"]}, commit {run["head_sha"]}')
    if os.getenv('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'run_id={run["id"]}\nsource_sha={run["head_sha"]}\n')
    if os.getenv('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(f'### Ad-hoc from PR #{args.pr}\n\n'
                          f'- Source: `{run["head_sha"]}`\n'
                          f'- Existing CI: {run["html_url"]}\n'
                          '- Reuses the unsigned archive; no compile or simulator test rerun.\n'
                          '- Simulator tests do not gate signing; review their results in the source CI.\n'
                          '- No TestFlight upload. Approve the protected ad-hoc signing job.\n')


if __name__ == '__main__':
    main()
