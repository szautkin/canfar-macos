#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Make the user manual's website readable by AI agents, after `mkdocs build`.

Writes, into the built site:

- /llms.txt: the index agents look for (llmstxt.org): what the manual is, and each chapter, in
  English and French, with one line on it and a link to its Markdown;
- /llms-full.txt: the whole manual, English then French, in one Markdown file;
- /<lang>/<chapter>.md: the Markdown of each page, next to its HTML.

Run from anywhere: python3 scripts/manual-llms.py [site]   (default: site)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANUAL = os.path.join(ROOT, 'docs', 'manual')
LANGS = (('en', 'English'), ('fr', 'Français'))
AGENTS = 'https://github.com/szautkin/canfar-macos/blob/main/AGENTS.md'


def site_url():
    with open(os.path.join(ROOT, 'mkdocs.yml'), encoding='utf-8') as f:
        return re.search(r'^site_url:\s*(\S+)', f.read(), re.M).group(1).rstrip('/') + '/'


def chapters(lang):
    folder = os.path.join(MANUAL, lang)
    for name in sorted(f for f in os.listdir(folder) if f.endswith('.md')):
        with open(os.path.join(folder, name), encoding='utf-8') as f:
            yield name, f.read()


def summary(markdown):
    """The chapter's first paragraph, as one line."""
    for block in re.split(r'\n\s*\n', markdown):
        block = block.strip()
        if block and not block.startswith(('#', '!', '|', '-', '```')) and not re.match(r'\d+\. ', block):
            text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', ' '.join(block.split()))
            return re.sub(r'\*\*([^*]+)\*\*', r'\1', text)
    return ''


def absolute(markdown, lang, base):
    """Links and pictures of a chapter, made absolute for a file at the site's root."""
    markdown = re.sub(r'\]\(\.\./images/', f']({base}images/', markdown)
    markdown = re.sub(r'\]\(\.\./(en|fr)/([\w-]+)\.md', lambda m: f']({base}{m.group(1)}/{m.group(2)}.md', markdown)
    return re.sub(r'\]\(([\w-]+)\.md', lambda m: f']({base}{lang}/{m.group(1)}.md', markdown)


def main():
    site = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'site'))
    base = site_url()
    index = [
        '# Verbinal user manual',
        '',
        '> The manual of Verbinal, the Mac app for the Canadian Astronomy Data Centre (CADC) and the CANFAR '
        'science platform: archive search, FITS and cube viewers, VOSpace storage, sessions, batch jobs, '
        'Remote Compute, and working with an AI assistant over MCP. In English and French, for Verbinal 1.4.',
        '',
        'Each chapter below links its Markdown. The same page as HTML is at the same address, without `.md`. '
        f'To connect an AI agent to Verbinal itself, read [AGENTS.md]({AGENTS}).',
        '',
    ]
    full = []
    for lang, language in LANGS:
        index += [f'## {language}', '']
        os.makedirs(os.path.join(site, lang), exist_ok=True)
        for name, markdown in chapters(lang):
            title = re.search(r'^# (.+)$', markdown, re.M).group(1)
            with open(os.path.join(site, lang, name), 'w', encoding='utf-8') as f:
                f.write(markdown)
            index.append(f'- [{title}]({base}{lang}/{name}): {summary(markdown)}')
            full.append(absolute(markdown, lang, base).strip())
        index.append('')
    index += ['## Optional', '', f'- [The whole manual in one file]({base}llms-full.txt)',
              f'- [Connecting an AI agent to Verbinal]({AGENTS})', '']
    with open(os.path.join(site, 'llms.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(index))
    with open(os.path.join(site, 'llms-full.txt'), 'w', encoding='utf-8') as f:
        f.write('\n\n---\n\n'.join(full) + '\n')
    print(f'llms.txt, llms-full.txt and {len(full)} Markdown pages in {os.path.relpath(site, ROOT)}')


if __name__ == '__main__':
    main()
