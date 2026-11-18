#!/usr/bin/env python3
"""Validate supplied profiles and generate manual Xcode export options."""
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def validate_profile(profile, team, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if team not in profile.get('TeamIdentifier', []):
        raise ValueError('Profile belongs to a different Apple team')
    if profile['ExpirationDate'] <= now:
        raise ValueError('Provisioning profile expired')
    entitlements = profile['Entitlements']
    prefix, bundle = entitlements['application-identifier'].split('.', 1)
    if prefix not in profile.get('ApplicationIdentifierPrefix', []) or '*' in bundle:
        raise ValueError('An explicit App ID profile is required')
    if entitlements.get('get-task-allow'):
        raise ValueError('Use distribution profiles, not development profiles')
    if profile.get('ProvisionsAllDevices'):
        raise ValueError('Enterprise profiles are not supported')
    if profile.get('ProvisionedDevices'):
        raise ValueError('TestFlight requires App Store distribution profiles')
    if not re.fullmatch(r'[A-Fa-f0-9-]{36}', profile['UUID']):
        raise ValueError('Invalid profile UUID')
    return bundle


def main():
    from archive import validate, bundles
    archive, profile_dir, destination = map(Path, sys.argv[1:])
    config = json.loads(os.environ['APP_CONFIG'])
    team = os.environ['APPLE_TEAM_ID']
    validate(archive, config['bundle_ids'])
    profiles = {}
    for path in profile_dir.rglob('*.mobileprovision'):
        raw = subprocess.check_output(['security', 'cms', '-D', '-i', str(path)])
        profile = plistlib.loads(raw)
        bundle = validate_profile(profile, team)
        if bundle in profiles:
            raise ValueError(f'Duplicate profiles for {bundle}')
        profiles[bundle] = (profile, path)
    if set(profiles) != set(config['bundle_ids']):
        raise ValueError('Supply exactly one profile per configured app/extension bundle ID')
    for app in bundles(archive):
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        bundle = info['CFBundleIdentifier']
        # The app and keyboard share the App Group; the widget does not use it.
        if bundle != f'{config["bundle_id"]}.widgets':
            groups = profiles[bundle][0]['Entitlements'].get('com.apple.security.application-groups', [])
            if f'group.{config["bundle_id"]}' not in groups:
                raise ValueError(f'Missing App Group in profile for {bundle}')
    installed = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
    installed.mkdir(parents=True, exist_ok=True)
    installed_paths = []
    for profile, path in profiles.values():
        target = installed / f'{profile["UUID"]}.mobileprovision'
        target.write_bytes(path.read_bytes())
        installed_paths.append(str(target))
    Path(os.environ['RUNNER_TEMP'], 'installed-profiles.json').write_text(json.dumps(installed_paths))
    options = {
        'method': 'app-store-connect',
        'teamID': team,
        'signingStyle': 'manual',
        'signingCertificate': 'Apple Distribution',
        'provisioningProfiles': {bundle: profile['UUID'] for bundle, (profile, _) in profiles.items()},
        'manageAppVersionAndBuildNumber': False,
        'stripSwiftSymbols': True,
        'uploadSymbols': False,
        'destination': 'export',
    }
    destination.write_bytes(plistlib.dumps(options))


if __name__ == '__main__':
    main()
