#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent


def keyboard_display_name(display_name):
    return f'{display_name} Keyboard'


def load():
    config = json.loads((HERE / 'app.json').read_text())
    if config['app'] != 'typr' or config['directory'] != 'ios':
        raise ValueError('app.json describes the Typr iOS app only')
    if not re.fullmatch(r'[A-Za-z0-9_-]+\.xcodeproj', config['project']):
        raise ValueError('Invalid Xcode project')
    if not re.fullmatch(r'[A-Za-z0-9_. -]+', config['scheme']):
        raise ValueError('Invalid Xcode scheme')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', config['product']):
        raise ValueError('Invalid product name')
    if not re.fullmatch(r'[A-Z0-9]{10}', config['team_id']):
        raise ValueError('Invalid team')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', config['bundle_id']):
        raise ValueError('Invalid bundle ID')
    if config['app_group'] != 'group.' + config['bundle_id']:
        raise ValueError('App Group must be group.<bundle ID>')
    if not re.fullmatch(r'[A-Za-z0-9+ ._-]{1,30}', config['display_name']):
        raise ValueError('Invalid display name')
    offsets = config['build_number_offsets']
    if not all(isinstance(v, int) and v > 0 for v in offsets.values()):
        raise ValueError('Invalid build number offset')
    for suffix in config['extension_suffixes']:
        if not re.fullmatch(r'[A-Za-z0-9-]+', suffix):
            raise ValueError('Invalid extension suffix')
    config['bundle_ids'] = [config['bundle_id']] + [
        f'{config["bundle_id"]}.{suffix}' for suffix in config['extension_suffixes']
    ]
    return config


def marketing_version(root):
    tokens = re.findall(r'^\s*MARKETING_VERSION: *(.*?) *(?:#.*)?$',
                        (Path(root) / 'ios/project.yml').read_text(), re.M)
    versions = {re.sub(r'^(["\'])(.*)\1$', r'\2', token) for token in tokens}
    if len(versions) != 1:
        raise ValueError(f'Expected one marketing version, found {sorted(versions)}')
    version = versions.pop()
    if not re.fullmatch(r'\d+(?:\.\d+){1,2}', version):
        raise ValueError(f'Unsupported marketing version {version!r}')
    return version


def build_number_offset(config, version):
    return config['build_number_offsets'].get(version, 0)


if __name__ == '__main__':
    if len(sys.argv) == 2:
        print(build_number_offset(load(), marketing_version(sys.argv[1])))
        raise SystemExit
    serialized = json.dumps(load(), separators=(',', ':'))
    print(serialized)
    if os.getenv('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'config={serialized}\n')
