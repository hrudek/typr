#!/usr/bin/env python3
"""Usage: overlay.py <repo root>"""
from pathlib import Path
import re
import sys

from config import load

UPSTREAM_TEAM = '5NZ4Q7NXJ4'
UPSTREAM_BUNDLE = 'anomaly.hex.mobile'
UPSTREAM_GROUP = 'group.anomaly.hex.mobile'
UPSTREAM_ICON = '../app/AppIcon.icon'
TYPR_ICON = '../.github/typr/AppIcon.icon'
SWIFT_DECLARATIONS = ('static let appGroup = "{app_group}"',
                      'static let keyboardBundleID = "{bundle_id}.keyboard"')


def sub(text, pattern, replacement, expected, what):
    result, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != expected:
        raise ValueError(f'{what}: expected {expected} match(es), found {count}')
    return result


def patch_project(text, config):
    ids = config['bundle_id']
    text = sub(text, r'^(\s+bundleIdPrefix: )anomaly\.hex$', rf'\g<1>{ids}', 1, 'bundleIdPrefix')
    text = sub(text, rf'^(\s+DEVELOPMENT_TEAM: ){UPSTREAM_TEAM}$', rf'\g<1>{config["team_id"]}', 1, 'team')
    text = sub(text, rf'^(\s+PRODUCT_BUNDLE_IDENTIFIER: ){re.escape(UPSTREAM_BUNDLE)}((?:\.(?:keyboard|widgets|tests))?)$',
               rf'\g<1>{ids}\g<2>', 4, 'bundle IDs')
    text = sub(text, r'^(\s+CFBundleDisplayName: ).+$', rf'\g<1>{config["display_name"]}', 3, 'display names')
    text = sub(text, rf'^(\s+- path: ){re.escape(UPSTREAM_ICON)}$', rf'\g<1>{TYPR_ICON}', 1, 'app icon')
    return text


def entitlement_paths(project):
    return re.findall(r'^\s+CODE_SIGN_ENTITLEMENTS: (\S+)$', project, re.MULTILINE)


def apply(root, config):
    ios = Path(root) / 'ios'
    project_file = ios / 'project.yml'
    project = patch_project(project_file.read_text(), config)
    project_file.write_text(project)
    paths = entitlement_paths(project)
    if len(paths) != 2:
        raise ValueError(f'Expected app and keyboard entitlements, found {paths}')
    for raw in paths:
        path = ios / raw
        path.write_text(sub(path.read_text(), rf'<string>{re.escape(UPSTREAM_GROUP)}</string>',
                            f'<string>{config["app_group"]}</string>', 1, raw))
    replacements = {f'"{UPSTREAM_GROUP}"': f'"{config["app_group"]}"',
                    f'"{UPSTREAM_BUNDLE}.keyboard"': f'"{config["bundle_id"]}.keyboard"'}
    swift = []
    for path in ios.rglob('*.swift'):
        text = path.read_text()
        changed = text
        for old, new in replacements.items():
            changed = changed.replace(old, new)
        if changed != text:
            path.write_text(changed)
        swift.append(changed)
    corpus = '\n'.join(swift)
    for declaration in SWIFT_DECLARATIONS:
        declaration = declaration.format(**config)
        if corpus.count(declaration) != 1:
            raise ValueError(f'Expected one `{declaration}`; upstream moved it')
    (ios / 'HEXMobile/Feedback.local.xcconfig').write_text('BELLHOP_REPORT_KEY =\n')
    verify(root, config)


def verify(root, config):
    ios = Path(root) / 'ios'
    project = (ios / 'project.yml').read_text()
    ids = re.findall(r'^\s+PRODUCT_BUNDLE_IDENTIFIER: (\S+)$', project, re.MULTILINE)
    expected = config['bundle_ids'] + [config['bundle_id'] + '.tests']
    if sorted(ids) != sorted(expected):
        raise ValueError(f'Unexpected bundle IDs {ids}')
    if UPSTREAM_TEAM in project:
        raise ValueError('Upstream team left in project.yml')
    leftovers = [str(p.relative_to(ios)) for p in ios.rglob('*')
                 if p.is_file() and p.suffix in ('.swift', '.plist', '.entitlements', '.yml')
                 and UPSTREAM_GROUP in p.read_text(errors='ignore')]
    if leftovers:
        raise ValueError(f'Upstream App Group left in {leftovers}')


if __name__ == '__main__':
    apply(sys.argv[1], load())
    print('Typr identity applied')
