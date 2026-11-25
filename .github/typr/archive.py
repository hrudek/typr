#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import sys

from config import keyboard_display_name


def bundles(archive):
    apps = list((Path(archive) / 'Products/Applications').glob('*.app'))
    if len(apps) != 1:
        raise ValueError('Archive must contain exactly one main app')
    return apps + list(apps[0].rglob('*.appex'))


def identifiers(archive):
    return {
        plistlib.loads((bundle / 'Info.plist').read_bytes())['CFBundleIdentifier']
        for bundle in bundles(archive)
    }


def validate(archive, expected, display_name=None):
    actual = identifiers(archive)
    if actual != set(expected):
        raise ValueError(f'Unexpected archive bundle IDs: {actual}; expected {set(expected)}')
    if display_name is not None:
        for bundle in bundles(archive):
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            name = info.get('CFBundleDisplayName')
            wanted = keyboard_display_name(display_name) if info['CFBundleIdentifier'].endswith('.keyboard') else display_name
            if name != wanted:
                raise ValueError(f'Unexpected display name {name!r} in {bundle.name}')


if __name__ == '__main__':
    config = json.loads(os.environ['APP_CONFIG'])
    validate(sys.argv[1], config['bundle_ids'], config['display_name'])
