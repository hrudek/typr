#!/usr/bin/env python3
"""Validate, encrypt and describe an unsigned native archive."""
import json
import os
from pathlib import Path
import shutil
import subprocess
from archive import validate

config = json.loads(os.environ['APP_CONFIG'])
output = Path(os.environ['RUNNER_TEMP']) / 'output'
archive = output / 'App.xcarchive'
validate(archive, config['bundle_ids'], config['display_name'])
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                str(archive), str(output / 'archive.zip')], check=True)
subprocess.run(['age', '--encrypt', '--recipient', os.environ['ARTIFACT_AGE_RECIPIENT'],
                '--output', str(output / 'archive.zip.age'), str(output / 'archive.zip')], check=True)
shutil.rmtree(archive)
(output / 'archive.zip').unlink()
metadata = {
    'app': config,
    'source_sha': os.environ['SOURCE_SHA'],
    'workflow_sha': os.environ.get('GITHUB_SHA'),
    'run': os.environ.get('GITHUB_RUN_ID'),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'distribution': 'age-encrypted unsigned archive, NOT installable',
}
(output / 'build.json').write_text(json.dumps(metadata, indent=2))
