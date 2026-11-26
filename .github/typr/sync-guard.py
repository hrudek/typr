#!/usr/bin/env python3
"""Decide whether this upstream-sync run should sync (typr-sync.yml).

usage: sync-guard.py EVENT [REPO]

GitHub delivers schedules late or not at all, so the workflow has several cron slots per day.
Only the first scheduled run of a Berlin day syncs: a successful sync leaves a
"chore(typr): upstream sync to … [skip ci]" marker on dev, and a scheduled run that finds one
committed today (Europe/Berlin) skips. A noop or failed sync leaves no marker, so a later slot
tries again. Any other event (workflow_dispatch) always syncs.
Prints `run=true|false` on stdout (the step output) and the reason on stderr. REPO's HEAD must be the
live dev tip: the workflow checks out `dev`, not the commit that triggered the run.
"""
import re
import subprocess
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

BERLIN = ZoneInfo('Europe/Berlin')
MARKER = re.compile(r'chore\(typr\): upstream sync to .* \[skip ci\]')


def decide(event, repo='.', now=None):
    if event != 'schedule':
        return True, f'{event} run: always syncs.'
    today = (now or datetime.now(BERLIN)).astimezone(BERLIN).date()
    log = subprocess.run(['git', '-C', repo, 'log', '-n', '50', '--format=%H %cI %s', 'HEAD'],
                         check=True, capture_output=True, text=True).stdout.splitlines()
    for line in log:
        sha, stamp, subject = line.split(' ', 2)
        if MARKER.fullmatch(subject) and datetime.fromisoformat(stamp).astimezone(BERLIN).date() == today:
            return False, f'Already synced today ({today}, Berlin) by marker {sha[:8]}; skipping this scheduled run.'
    return True, f'No sync marker for {today} (Berlin); syncing.'


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit('usage: sync-guard.py EVENT [REPO]')
    run, message = decide(sys.argv[1], *sys.argv[2:])
    print(f'run={str(run).lower()}')
    print(message, file=sys.stderr)
