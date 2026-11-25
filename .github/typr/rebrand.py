"""User-visible "Hex" becomes "Typr" in ios/: one rewrite for String Catalog keys and
values, Swift string literals (lookup keys) and Info.plist strings, so lookups keep matching."""
from pathlib import Path
import json
import re

BRAND = re.compile(r'(?<![A-Za-z0-9_./-])Hex(?![A-Za-z0-9_-]|\.[A-Za-z0-9])')
OTHER_PLATFORM_APPS = ('Hex on a Mac',)
FILE_NAMES = ('hex-words.hexwords', '.hexwords')
CATALOGS = ('HEXMobile/Localizable.xcstrings', 'HEXWidgets/Localizable.xcstrings',
            'HEXMobile/AppShortcuts.xcstrings')
INFO_PLISTS = ('HEXMobile/Info.plist', 'HEXKeyboard/Info.plist', 'HEXWidgets/Info.plist')
INFO_PLIST_STRINGS = 'HEXMobile/zh-Hans.lproj/InfoPlist.strings'
PROJECT_STRINGS = (r'^(\s+(?:- )?(?:CFBundleDisplayName|NS\w+UsageDescription|CFBundleTypeName|UTTypeDescription): )'
                   r'(.*)$')
TESTS = 'HEXMobileTests'
ANCHORS = ('Hex key', 'Open Hex', 'Dictate with Hex', 'Hex Keyboard', "Hex couldn't start the microphone. Try again.")


def names_other_app(text):
    return any(app in text for app in OTHER_PLATFORM_APPS)


def brand(text):
    return text if names_other_app(text) else BRAND.sub('Typr', text)


def brand_test_literal(text):
    return text if text == 'Hex' else brand(text)


def count(pattern, text, expected, what):
    found = len(re.findall(pattern, text, re.MULTILINE))
    if found != expected:
        raise ValueError(f'{what}: expected {expected} match(es), found {found}')


def swift_literals(source, rewrite):
    """Applies `rewrite` to the text of every string literal in `source`, outside comments,
    escapes and interpolations. Returns (new source, literal texts after the rewrite)."""
    out, texts = [], []
    n = len(source)

    def code(i, in_interpolation):
        depth = 0
        while i < n:
            if source.startswith('//', i):
                end = source.find('\n', i)
                end = n if end < 0 else end
                out.append(source[i:end])
                i = end
            elif source.startswith('/*', i):
                i = comment(i)
            elif source[i] == '"' or (source[i] == '#' and re.match(r'#+"', source[i:i + 64])):
                i = string(i)
            elif source[i] == '(':
                depth += 1
                out.append('(')
                i += 1
            elif source[i] == ')' and in_interpolation and depth == 0:
                return i
            else:
                if source[i] == ')':
                    depth -= 1
                out.append(source[i])
                i += 1
        return i

    def comment(i):
        depth, start = 0, i
        while i < n:
            if source.startswith('/*', i):
                depth, i = depth + 1, i + 2
            elif source.startswith('*/', i):
                depth, i = depth - 1, i + 2
                if depth == 0:
                    break
            else:
                i += 1
        out.append(source[start:i])
        return i

    def string(i):
        hashes = len(source[i:]) - len(source[i:].lstrip('#'))
        quotes = '"""' if source.startswith('"""', i + hashes) else '"'
        opening = '#' * hashes + quotes
        closing = quotes + '#' * hashes
        escape = '\\' + '#' * hashes
        out.append(opening)
        i += len(opening)
        segment = []

        def flush():
            text = rewrite(''.join(segment))
            texts.append(text)
            out.append(text)
            segment.clear()

        while i < n:
            if source.startswith(closing, i):
                flush()
                out.append(closing)
                return i + len(closing)
            if source.startswith(escape + '(', i):
                flush()
                out.append(escape + '(')
                i = code(i + len(escape) + 1, True)
                out.append(')')
                i += 1
            elif source.startswith(escape, i):
                flush()
                out.append(source[i:i + len(escape) + 1])
                i += len(escape) + 1
            else:
                segment.append(source[i])
                i += 1
        raise ValueError('Unterminated Swift string literal')

    code(0, False)
    return ''.join(out), texts


def catalog_strings(node, rewrite=lambda text: text):
    """Every displayed string of a catalog entry (all locales and variants), after `rewrite`,
    which also replaces it in place."""
    found = []
    if isinstance(node, dict):
        if 'stringUnit' in node:
            node['stringUnit']['value'] = rewrite(node['stringUnit']['value'])
            found.append(node['stringUnit']['value'])
        if 'stringSet' in node:
            node['stringSet']['values'] = [rewrite(v) for v in node['stringSet']['values']]
            found += node['stringSet']['values']
        for key, value in node.items():
            if key not in ('stringUnit', 'stringSet'):
                found += catalog_strings(value, rewrite)
    elif isinstance(node, list):
        for value in node:
            found += catalog_strings(value, rewrite)
    return found


def rebrand_catalog(path):
    catalog = json.loads(path.read_text())
    strings = {}
    for key, entry in catalog['strings'].items():
        new_key = brand(key)
        if new_key in strings or (new_key != key and new_key in catalog['strings']):
            raise ValueError(f'{path.name}: "{key}" would replace the existing key "{new_key}"')
        if not names_other_app(key):
            catalog_strings(entry, brand)
        strings[new_key] = entry
    catalog['strings'] = strings
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(',', ' : ')) + '\n')


def apply(ios):
    ios = Path(ios)
    catalog = json.loads((ios / CATALOGS[0]).read_text())['strings']
    swift = {path: path.read_text() for path in ios.rglob('*.swift')}
    literals = set()
    for text in swift.values():
        literals.update(swift_literals(text, lambda s: s)[1])
    for anchor in ANCHORS:
        if anchor not in catalog or anchor not in literals:
            raise ValueError(f'Rebrand anchor "{anchor}" is no longer a Swift literal and catalog key')

    for name in CATALOGS:
        rebrand_catalog(ios / name)
    for path, text in swift.items():
        rewrite = brand_test_literal if TESTS in path.relative_to(ios).parts else brand
        changed = swift_literals(text, rewrite)[0]
        if changed != text:
            path.write_text(changed)
    for name in INFO_PLISTS:
        path = ios / name
        path.write_text(re.sub(r'<string>([^<]*)</string>',
                               lambda m: f'<string>{brand(m[1])}</string>', path.read_text()))
    strings = ios / INFO_PLIST_STRINGS
    text = strings.read_text()
    count(r'"[^"\n]*\bHex\b[^"\n]*"', text, 4, INFO_PLIST_STRINGS)
    strings.write_text(re.sub(r'"((?:[^"\\\n]|\\.)*)"', lambda m: f'"{brand(m[1])}"', text))
    project = ios / 'project.yml'
    text = project.read_text()
    count(PROJECT_STRINGS.replace('(.*)$', r'(.*\bHex\b.*)$'), text, 6, 'project.yml user-facing strings')
    project.write_text(re.sub(PROJECT_STRINGS, lambda m: m[1] + brand(m[2]), text, flags=re.MULTILINE))
    leftovers = find_leftovers(ios)
    if leftovers:
        raise ValueError('User-visible Hex left:\n' + '\n'.join(leftovers))


def visible_hex(text):
    if names_other_app(text):
        return False
    for name in FILE_NAMES:
        text = text.replace(name, '')
    return re.search('hex', text, re.IGNORECASE) is not None


def find_leftovers(ios):
    """User-visible strings that still say Hex: catalog keys and values in every locale,
    Info.plist and InfoPlist.strings values, project.yml user-facing strings, and app (not
    test) Swift literals with a capitalised Hex and a space (identifiers and lower-case ones
    such as "HexInbox" or "anomaly.hex.words" are not prose)."""
    ios = Path(ios)
    found = []
    for name in CATALOGS:
        for key, entry in json.loads((ios / name).read_text())['strings'].items():
            if not names_other_app(key):
                found += [f'{name}: {s!r}' for s in [key] + catalog_strings(entry) if visible_hex(s)]
    for name in INFO_PLISTS:
        found += [f'{name}: {v!r}' for v in re.findall(r'<string>([^<]*)</string>', (ios / name).read_text())
                  if 'Hex' in v]
    for line in (ios / INFO_PLIST_STRINGS).read_text().splitlines():
        if line.startswith('"') and visible_hex(line):
            found.append(f'{INFO_PLIST_STRINGS}: {line}')
    project = (ios / 'project.yml').read_text()
    found += [f'project.yml: {m[0].strip()}' for m in re.finditer(PROJECT_STRINGS, project, re.MULTILINE)
              if visible_hex(m[2])]
    for path in sorted(ios.rglob('*.swift')):
        relative = path.relative_to(ios)
        if TESTS in relative.parts:
            continue
        for text in swift_literals(path.read_text(), lambda s: s)[1]:
            if 'Hex' in text and re.search(r'\s', text) and not names_other_app(text):
                found.append(f'{relative}: {text!r}')
    return found
