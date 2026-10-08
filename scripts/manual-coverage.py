#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Check that the user manual (docs/manual/) covers the whole app, in both languages.

The manual is outside the app: this script reads the app's sources and the manual
and changes neither. It fails when

- a screen, an app-wide sheet, a Settings section, a menu item or a parity area
  (a `## ` of docs/agent-ui-parity.md) has no row in docs/manual/COVERAGE.md;
- a row's chapter or heading does not exist, or its label is not in the string
  catalogue, or is not named in that chapter — in English in en/, in French in fr/;
- a keyboard shortcut is not in the shortcuts appendix;
- en/ and fr/ differ in files, in their headings' levels, in their numbered steps,
  or in the pictures they show;
- a relative link, an anchor or a picture does not resolve.

Run from anywhere: python3 scripts/manual-coverage.py
"""
import json
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANUAL = os.path.join(ROOT, 'docs', 'manual')
LANGS = ('en', 'fr')
SHORTCUTS_CHAPTER = 'a-shortcuts-and-menus.md'
PICTURE_LIMIT = 400 * 1024

problems = []


def problem(text):
    problems.append(text)


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding='utf-8') as f:
        return f.read()


# --- The app's inventory, from its sources -----------------------------------

def enum_cases(source, enum_name):
    block = re.search(r'enum ' + enum_name + r'\b[^{]*\{(.*?)\n\}', source, re.S)
    cases = []
    for line in block.group(1).splitlines():
        m = re.match(r'\s*case ([a-zA-Z, ]+)$', line)
        if m:
            cases += [c.strip() for c in m.group(1).split(',')]
    return cases


def active_sheets():
    source = read('Verbinal', 'ViewModels', 'AppState.swift')
    m = re.search(r'enum ActiveSheet\b.*?\n\s*case ([a-zA-Z, ]+)\n', source, re.S)
    return [c.strip() for c in m.group(1).split(',')]


def menu_items():
    source = read('Verbinal', 'VerbinalApp.swift')
    commands = source[source.index('.commands {'):source.index('Settings {')]
    return (re.findall(r'CommandMenu\("([^"]+)"\)', commands)
            + re.findall(r'Button\("([^"]+)"\)', commands))


KEYS = {'return': '↩', 'delete': '⌫', 'escape': 'Esc', 'tab': '⇥', 'space': 'Space',
        'upArrow': '↑', 'downArrow': '↓', 'leftArrow': '←', 'rightArrow': '→'}
MODIFIERS = (('control', '⌃'), ('option', '⌥'), ('shift', '⇧'), ('command', '⌘'))


def shortcuts():
    """Every .keyboardShortcut of the Mac app, as the manual writes it (⌥⌘1)."""
    found = {}
    for folder, _, files in os.walk(os.path.join(ROOT, 'Verbinal')):
        if os.sep + 'iOS' in folder:
            continue
        for name in files:
            if not name.endswith('.swift'):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding='utf-8') as f:
                text = f.read()
            for m in re.finditer(r'\.keyboardShortcut\(([^)]*)\)', text):
                args = m.group(1)
                if 'defaultAction' in args or 'cancelAction' in args:
                    continue
                key = re.match(r'\s*(?:"([^"]+)"|\.(\w+))', args)
                key = key.group(1).upper() if key.group(1) else KEYS.get(key.group(2), key.group(2))
                mods = re.search(r'modifiers:\s*(\[[^\]]*\]|\.\w+)', args)
                mods = mods.group(1) if mods else '.command'
                combo = ''.join(sym for word, sym in MODIFIERS if '.' + word in mods) + key
                found.setdefault(combo, os.path.relpath(path, ROOT))
    return found


def parity_areas():
    return re.findall(r'^## (.+)$', read('docs', 'agent-ui-parity.md'), re.M)


def catalogue():
    strings = json.loads(read('Verbinal', 'Resources', 'Localizable.xcstrings'))['strings']
    french = {}
    for key, entry in strings.items():
        unit = entry.get('localizations', {}).get('fr', {}).get('stringUnit')
        french[key] = unit['value'] if unit else key
    return french


# --- The manual ----------------------------------------------------------------

def slug(heading):
    """GitHub's anchor for a heading."""
    text = re.sub(r'[*_`]', '', heading.strip().lower())
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    text = ''.join(c for c in text if c in ' -' or unicodedata.category(c)[0] in 'LN')
    return text.replace(' ', '-')


def chapter(lang, name):
    path = os.path.join(MANUAL, lang, name)
    if not os.path.exists(path):
        return None
    with open(path, encoding='utf-8') as f:
        return f.read()


def without_code(text):
    return re.sub(r'```.*?```', '', text, flags=re.S)


def headings(text):
    return re.findall(r'^(#{1,6}) (.+?)\s*$', without_code(text), re.M)


def anchors(text):
    seen, out = {}, set()
    for _, h in headings(text):
        s = slug(h)
        n = seen.get(s, 0)
        out.add(s if n == 0 else f'{s}-{n}')
        seen[s] = n + 1
    return out


def coverage_rows():
    """COVERAGE.md tables: {section: [(item, label, chapter, heading)]}."""
    text = read('docs', 'manual', 'COVERAGE.md')
    rows, section = {}, None
    for line in text.splitlines():
        m = re.match(r'^## (.+)$', line)
        if m:
            section = m.group(1).strip()
            rows[section] = []
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')] if line.startswith('|') else []
        if len(cells) == 4 and section and not set(cells[0]) <= set('-: ') and cells[0] != 'Item':
            item, label, chap, head = (c.strip('`') for c in cells)
            rows[section].append((item, label, chap, head))
    return rows


def check_rows(section, wanted, rows, french, need_label=True):
    by_item = {r[0]: r for r in rows.get(section, [])}
    for item in wanted:
        if item not in by_item:
            problem(f'COVERAGE.md ▸ {section}: no row for `{item}`')
    for item, label, chap, head in rows.get(section, []):
        if item not in wanted:
            problem(f'COVERAGE.md ▸ {section}: `{item}` is not in the app any more')
        en = chapter('en', chap)
        if en is None:
            problem(f'COVERAGE.md ▸ {section} ▸ {item}: no chapter en/{chap}')
            continue
        if head and head not in [h for _, h in headings(en)]:
            problem(f'COVERAGE.md ▸ {section} ▸ {item}: en/{chap} has no heading "{head}"')
        if not need_label or not label or label == '—':
            continue
        if label not in french:
            problem(f'COVERAGE.md ▸ {section} ▸ {item}: "{label}" is not in Localizable.xcstrings')
            continue
        for lang, words in (('en', label), ('fr', french[label])):
            text = chapter(lang, chap) or ''
            if words not in text:
                problem(f'{lang}/{chap} does not name "{words}" ({section} ▸ {item})')


def check_shortcuts():
    for lang in LANGS:
        text = chapter(lang, SHORTCUTS_CHAPTER) or ''
        for combo, where in sorted(shortcuts().items()):
            if combo not in text:
                problem(f'{lang}/{SHORTCUTS_CHAPTER} has no {combo} (used in {where})')


def shape(text):
    body = without_code(text)
    return ([len(level) for level, _ in headings(text)],
            len(re.findall(r'^\s*\d+\. ', body, re.M)),
            [os.path.basename(p) for p in re.findall(r'!\[[^\]]*\]\(([^)\s]+)', body)])


def check_languages():
    files = {lang: sorted(f for f in os.listdir(os.path.join(MANUAL, lang)) if f.endswith('.md'))
             for lang in LANGS}
    if files['en'] != files['fr']:
        problem(f'en/ and fr/ have different files: {sorted(set(files["en"]) ^ set(files["fr"]))}')
    for name in sorted(set(files['en']) & set(files['fr'])):
        en, fr = shape(chapter('en', name)), shape(chapter('fr', name))
        for what, a, b in (('heading levels', en[0], fr[0]), ('numbered steps', en[1], fr[1]),
                           ('pictures', en[2], fr[2])):
            if a != b:
                problem(f'{name}: en and fr differ in {what}: {a} ≠ {b}')


def check_links():
    for folder, _, files in os.walk(MANUAL):
        for name in files:
            if not name.endswith('.md'):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding='utf-8') as f:
                text = without_code(f.read())
            for m in re.finditer(r'(!?)\[[^\]]*\]\(([^)\s]+)\)', text):
                picture, target = m.group(1), m.group(2)
                if re.match(r'[a-z]+:', target):
                    continue
                file_part, _, anchor = target.partition('#')
                where = os.path.normpath(os.path.join(folder, file_part)) if file_part else path
                rel = os.path.relpath(path, ROOT)
                if not os.path.exists(where):
                    problem(f'{rel}: {"picture" if picture else "link"} {target} does not resolve')
                    continue
                if picture and os.path.getsize(where) > PICTURE_LIMIT:
                    problem(f'{rel}: picture {target} is over {PICTURE_LIMIT // 1024} KB')
                if anchor and where.endswith('.md'):
                    with open(where, encoding='utf-8') as f:
                        if anchor not in anchors(f.read()):
                            problem(f'{rel}: no heading for #{anchor} in {os.path.relpath(where, ROOT)}')


def main():
    french = catalogue()
    rows = coverage_rows()
    app_state = read('Verbinal', 'ViewModels', 'AppState.swift')
    settings = read('Verbinal', 'Settings', 'Shared', 'SettingsSection.swift')
    check_rows('Screens', enum_cases(app_state, 'AppMode'), rows, french)
    check_rows('Sheets', active_sheets(), rows, french)
    check_rows('Settings', enum_cases(settings, 'SettingsSection'), rows, french)
    check_rows('Menus', menu_items(), rows, french)
    check_rows('Interaction areas', parity_areas(), rows, french, need_label=False)
    check_shortcuts()
    check_languages()
    check_links()
    if problems:
        print(f'The manual is not complete — {len(problems)} problem(s):')
        for p in problems:
            print('  - ' + p)
        sys.exit(1)
    print('The manual covers the app, in English and French.')


if __name__ == '__main__':
    main()
