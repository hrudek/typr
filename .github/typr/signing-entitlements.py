#!/usr/bin/env python3
"""Seed unsigned archives with reviewed entitlements; check exported IPA signatures.

Xcode export of a CODE_SIGNING_ALLOWED=NO archive can otherwise produce valid
signatures containing only identity entitlements, silently losing App Groups.
Never copy every entitlement permitted by a profile into an application.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import zipfile

from archive import bundles, validate


def required_entitlements(config, bundle_id):
    if bundle_id not in config['bundle_ids']:
        raise ValueError('Unexpected bundle ID')
    if config['app'] != 'typr':
        raise ValueError('Review signing entitlements before signing another app')
    # The widget extension does not access shared storage; app + keyboard do.
    if bundle_id == f'{config["bundle_id"]}.widgets':
        return {}
    # Upstream Hex's app and keyboard entitlements hold only the App Group.
    return {'com.apple.security.application-groups': [config['app_group']]}


def validate_entitlements(actual, required, bundle_id, team):
    if actual.get('com.apple.developer.team-identifier') != team:
        raise ValueError(f'Wrong signing team: {bundle_id}')
    app_id = actual.get('application-identifier', '')
    if '.' not in app_id or app_id.split('.', 1)[1] != bundle_id:
        raise ValueError(f'Wrong signed application identifier: {bundle_id}')
    if actual.get('get-task-allow') is not False:
        raise ValueError(f'Expected distribution entitlements: {bundle_id}')
    for key, value in required.items():
        if actual.get(key) != value:
            raise ValueError(f'Missing or unexpected signed entitlement {key}: {bundle_id}')


def seed(archive, profile_dir, keychain, config, team):
    validate(archive, config['bundle_ids'])
    profiles = {}
    for path in profile_dir.rglob('*.mobileprovision'):
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(path)]))
        bundle_id = profile['Entitlements']['application-identifier'].split('.', 1)[1]
        if bundle_id in profiles:
            raise ValueError('Duplicate profile')
        profiles[bundle_id] = (profile, path)
    if set(profiles) != set(config['bundle_ids']):
        raise ValueError('Profile target set mismatch')
    targets = bundles(archive)
    # Sign embedded code inside-out, then extensions, then the containing app.
    nested = [p for p in targets[0].rglob('*') if p.suffix == '.framework' and p.is_dir()
              or p.suffix == '.dylib' and p.is_file()]
    with tempfile.TemporaryDirectory() as tmp:
        for target in sorted(nested + targets, key=lambda p: len(p.parts), reverse=True):
            command = ['codesign', '--force', '--sign', 'Apple Distribution',
                       '--keychain', str(keychain), '--generate-entitlement-der']
            if target in targets:
                info = plistlib.loads((target / 'Info.plist').read_bytes())
                bundle_id = info['CFBundleIdentifier']
                profile, profile_path = profiles[bundle_id]
                allowed = profile['Entitlements']
                required = required_entitlements(config, bundle_id)
                for key, value in required.items():
                    if allowed.get(key) != value:
                        raise ValueError(f'Profile does not permit {key}: {bundle_id}')
                entitlements = {**required, 'application-identifier': allowed['application-identifier'],
                                'com.apple.developer.team-identifier': team, 'get-task-allow': False}
                validate_entitlements(entitlements, required, bundle_id, team)
                entitlements_path = Path(tmp) / f'{bundle_id}.plist'
                entitlements_path.write_bytes(plistlib.dumps(entitlements))
                (target / 'embedded.mobileprovision').write_bytes(profile_path.read_bytes())
                command += ['--entitlements', str(entitlements_path)]
            subprocess.run(command + [str(target)], check=True)


def verify(ipa, config, team):
    # Inspect the actual Mach-O signatures, not just embedded profiles. Read only
    # exact bundle executables from the ZIP; do not extract arbitrary ZIP paths.
    actual_ids = set()
    with zipfile.ZipFile(ipa) as archive, tempfile.TemporaryDirectory() as tmp:
        for name in archive.namelist():
            if not name.endswith('/Info.plist'):
                continue
            parts = Path(name).parts
            main = len(parts) == 3 and parts[0] == 'Payload' and parts[1].endswith('.app')
            extension = (len(parts) == 5 and parts[0] == 'Payload' and parts[1].endswith('.app')
                         and parts[2] == 'PlugIns' and parts[3].endswith('.appex'))
            if not (main or extension):
                continue
            info = plistlib.loads(archive.read(name))
            bundle_id = info['CFBundleIdentifier']
            if bundle_id in actual_ids:
                raise ValueError('Duplicate IPA bundle ID')
            actual_ids.add(bundle_id)
            executable = info['CFBundleExecutable']
            if not executable or Path(executable).name != executable:
                raise ValueError('Invalid bundle executable')
            binary = Path(tmp) / 'executable'
            binary.write_bytes(archive.read(str(Path(name).parent / executable)))
            raw = subprocess.check_output(['codesign', '--display', '--entitlements', ':-', str(binary)])
            signed = plistlib.loads(raw)
            validate_entitlements(signed, required_entitlements(config, bundle_id), bundle_id, team)
            print(f'Verified signed entitlements: {bundle_id}')
    if actual_ids != set(config['bundle_ids']):
        raise ValueError('IPA target set mismatch')


if __name__ == '__main__':
    config = json.loads(os.environ['APP_CONFIG'])
    team = os.environ['APPLE_TEAM_ID']
    if sys.argv[1] == 'seed':
        seed(*map(Path, sys.argv[2:5]), config, team)
    elif sys.argv[1] == 'verify':
        verify(Path(sys.argv[2]), config, team)
    else:
        raise SystemExit('Expected seed or verify')
