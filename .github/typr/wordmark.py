"""The "typr." wordmark alone replaces the mark and brand name in the app's header rows."""
from pathlib import Path
import re
import shutil

IMAGESET = Path(__file__).resolve().parent / 'wordmark/TyprWordmark.imageset'
CATALOG = 'HEXMobile/Assets.xcassets'
VIEW = 'HEXMobile/ContentView.swift'
HEADER = (r'^( +)HexMarkView\(\n'
          r' +size: 20,\n'
          r' +color: \w+ \? HexTheme\.warmPearl : HexTheme\.textBase\n'
          r' +\)\n\n'
          r' +Text\("Hex"\)\n'
          r' +\.font\(\.system\(size: 17, weight: \.semibold\)\)\n'
          r' +\.tracking\(-0\.2\)\n'
          r' +\.foregroundStyle\(HexTheme\.textBase\)$')
WORDMARK = ('\\1Image("TyprWordmark")\n'
            '\\1    .foregroundStyle(HexTheme.textBase)\n'
            '\\1    .accessibilityLabel("Typr")')
HEADERS = 2


def apply(ios):
    ios = Path(ios)
    target = ios / CATALOG / IMAGESET.name
    if target.exists():
        raise ValueError(f'{target.relative_to(ios)} already exists')
    shutil.copytree(IMAGESET, target)
    view = ios / VIEW
    text, count = re.subn(HEADER, WORDMARK, view.read_text(), flags=re.MULTILINE)
    if count != HEADERS:
        raise ValueError(f'{VIEW}: expected {HEADERS} header lockup(s) to swap for the wordmark, found {count}')
    view.write_text(text)
