#!/usr/bin/env python3
"""Local only: create or reuse Typr's provisioning profiles and store them as a secret.

Usage: python3 .github/typr/provision.py ad-hoc|testflight

Uses the private Apple API helper in ~/.local/share/ios-build-signing (never in
Git). Reuses an ACTIVE profile with the expected name, else creates one (a new
"revision N" name when an older one went INVALID). Never deletes or revokes
anything. Ad Hoc profiles use exactly the devices of the existing Ad Hoc
profiles. Checks team, bundle ID and App Group before uploading the profile ZIP
to the environment typr-<distribution> of hrudek/typr.
"""
import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import urllib.parse
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from config import load  # noqa: E402

ROOT = Path.home() / '.local/share/ios-build-signing'
REPO = 'hrudek/typr'
TYPES = {'ad-hoc': ('IOS_APP_ADHOC', 'Typr Ad Hoc'), 'testflight': ('IOS_APP_STORE', 'Typr App Store')}


def decode(path):
    raw = subprocess.check_output(['openssl', 'cms', '-verify', '-inform', 'DER', '-in', str(path),
                                   '-noverify'], stderr=subprocess.DEVNULL)
    return plistlib.loads(raw)


def main(distribution):
    profile_type, prefix = TYPES[distribution]
    os.umask(0o077)
    spec = importlib.util.spec_from_file_location('local_apple', ROOT / 'apple-api.py')
    apple = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(apple)
    config = load()
    team = os.environ.get('APPLE_TEAM_ID', '2ZNGF24932')
    certificate = (ROOT / 'distribution-certificate-id.txt').read_text().strip()
    devices = []
    if distribution == 'ad-hoc':
        old = decode(sorted((ROOT / 'typr-ad-hoc').glob('*.mobileprovision'))[0])
        listed = apple.request('GET', '/v1/devices?filter[platform]=IOS&limit=200')['data']
        devices = [d['id'] for d in listed if d['attributes']['udid'] in old['ProvisionedDevices']
                   and d['attributes']['status'] == 'ENABLED']
        if len(devices) != len(old['ProvisionedDevices']):
            raise SystemExit('A registered test device is missing or disabled')
    destination = ROOT / f'typr-{distribution}'
    destination.mkdir(mode=0o700, exist_ok=True)
    paths = []
    for bundle in config['bundle_ids']:
        ids = [i for i in apple.request('GET', '/v1/bundleIds?filter[identifier]=' + bundle + '&limit=200')['data']
               if i['attributes']['identifier'] == bundle]
        if len(ids) != 1:
            raise SystemExit('Expected one registered bundle ID: ' + bundle)
        name = f'{prefix} {bundle}'
        listed = apple.request('GET', '/v1/profiles?limit=200&filter[name]=' + urllib.parse.quote(name))['data']
        matching = [p for p in listed if p['attributes']['name'] == name
                    or p['attributes']['name'].startswith(name + ' revision ')]
        active = [p for p in matching if p['attributes']['profileState'] == 'ACTIVE']
        if len(active) > 1:
            raise SystemExit('Several active profiles; review in the portal: ' + name)
        if active:
            profile = active[0]
            print('Reusing profile:', profile['attributes']['name'])
        else:
            if matching:
                used = {p['attributes']['name'] for p in matching}
                revision = 1
                while f'{name} revision {revision}' in used:
                    revision += 1
                name = f'{name} revision {revision}'
            relationships = {
                'bundleId': {'data': {'type': 'bundleIds', 'id': ids[0]['id']}},
                'certificates': {'data': [{'type': 'certificates', 'id': certificate}]},
            }
            if devices:
                relationships['devices'] = {'data': [{'type': 'devices', 'id': d} for d in devices]}
            profile = apple.request('POST', '/v1/profiles', {'data': {
                'type': 'profiles', 'attributes': {'name': name, 'profileType': profile_type},
                'relationships': relationships}})['data']
            print('Created profile:', name)
        path = destination / f'{bundle}.mobileprovision'
        path.write_bytes(base64.b64decode(profile['attributes']['profileContent']))
        data = decode(path)
        if team not in data['TeamIdentifier']:
            raise SystemExit('Wrong team in ' + name)
        if data['Entitlements']['application-identifier'].split('.', 1)[1] != bundle:
            raise SystemExit('Wrong bundle ID in ' + name)
        if bool(data.get('ProvisionedDevices')) != (distribution == 'ad-hoc'):
            raise SystemExit('Unexpected device list in ' + name)
        group = data['Entitlements'].get('com.apple.security.application-groups')
        if not bundle.endswith('.widgets') and group != ['group.' + config['bundle_id']]:
            raise SystemExit(f'App Group missing in {name}; assign it in the portal and rerun')
        if bundle == config['bundle_id'] and data['Entitlements'].get(
                'com.apple.developer.background-tasks.continued-processing.inference') is not True:
            raise SystemExit(f'Background Inference missing in {name}; enable it for the app in the '
                             'portal and regenerate the profile before rerunning')
        paths.append(path)
    archive = ROOT / f'typr-{distribution}-profiles.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for path in paths:
            output.write(path, path.name)
    subprocess.run(['gh', 'secret', 'set', 'IOS_PROFILES_ZIP_BASE64', '--repo', REPO,
                    '--env', f'typr-{distribution}'],
                   input=base64.b64encode(archive.read_bytes()), check=True)
    print(f'Uploaded {len(paths)} validated profiles to environment typr-{distribution}.')


if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] not in TYPES:
        raise SystemExit('usage: provision.py ad-hoc|testflight')
    main(sys.argv[1])
