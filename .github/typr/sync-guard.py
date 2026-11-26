#!/usr/bin/env python3
"""Decide whether this upstream-sync run should sync (typr-sync.yml).

usage: sync-guard.py EVENT [REPO] [NOW_ISO]

GitHub delivers schedules late or not at all, so the workflow has several cron slots per day.
Only the first scheduled run of a Berlin day syncs: a successful sync leaves a
"chore(typr): upstream sync to … [skip ci]" marker on dev, and a scheduled run that finds one
committed today (Europe/Berlin) skips. A noop or failed sync leaves no marker, so a later slot
tries again. Any other event (workflow_dispatch) always syncs.
Prints `run=true|false` and a log line on stdout (the first line is the step output).
"""
import subprocess
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

BERLIN = ZoneInfo('Europe/Berlin')
MARKER = r'^chore\(typr\): upstream sync to .* \[skip ci\]$'


def decide(event, repo='.', now=None):
    if event != 'schedule':
        return True, f'{event} run: always syncs.'
    today = (now or datetime.now(BERLIN)).astimezone(BERLIN).date()
    log = subprocess.run(['git', '-C', repo, 'log', '-n', '1', '--extended-regexp', f'--grep={MARKER}',
                          '--format=%H %cI', 'HEAD'], check=True, capture_output=True, text=True).stdout.split()
    if log:
        sha, stamp = log
        done = datetime.fromisoformat(stamp).astimezone(BERLIN).date()
        if done == today:
            return False, f'Already synced today ({today}, Berlin) by marker {sha[:8]}; skipping this scheduled run.'
    return True, f'No sync marker for {today} (Berlin); syncing.'


if __name__ == '__main__':
    event, repo, now = sys.argv[1], *sys.argv[2:], *[None] * (4 - len(sys.argv))
    repo = repo or '.'
    run, message = decide(event, repo, datetime.fromisoformat(now) if now else None)
    print(f'run={str(run).lower()}')
    print(message, file=sys.stderr)
