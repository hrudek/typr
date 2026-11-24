#!/usr/bin/env python3
"""Check that the archive contains exactly the configured app and extensions."""
import json
import os
from pathlib import Path
import plistlib
import sys


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
            name = plistlib.loads((bundle / 'Info.plist').read_bytes()).get('CFBundleDisplayName')
            if name != display_name:
                raise ValueError(f'Unexpected display name {name!r} in {bundle.name}')


if __name__ == '__main__':
    config = json.loads(os.environ['APP_CONFIG'])
    validate(sys.argv[1], config['bundle_ids'], config['display_name'])
