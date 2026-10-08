#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Take the user manual's pictures from the running Verbinal, through its own tools.

Each picture in docs/manual/pictures.json is a list of steps — Verbinal tools that
set the scene (navigate_to, select_ui, open_ui, …) — then a capture of the window as
the person sees it (capture_view). A picture can have:

- callouts: targets the app rings, numbered in the picture (1, 2, 3 …), each by its
  label, its id, or {"help": tooltip}, with "at": corner, above, below, left or right;
- targets by their English label, translated for French; "=Name" keeps a name the app
  never translates (a sheet's or popover's, as list_ui_targets' `presented` gives it);
- crop: [x, y, width, height] in window points;
- blur, blurFields, blurRects: words, text fields or rectangles to blur;
- blurRows: {"within": [x, y, w, h], "keep": [".fits", …]}: blur the rows of a list of
  the person's files, but for those ending so;
- after: steps that close what the picture opened. A change a step proposes that waits in
  Pending (an example for the picture) is withdrawn after the picture.

With --private, whatever shows the signed-in person's name or username is blurred too;
the name is read from the app at run time and never written anywhere. The result goes
to docs/manual/images/<lang>/<chapter>/.

The app's language is the person's setting (Settings ▸ General ▸ Language). Set it,
then run once per language:

    python3 scripts/manual-pictures.py --lang en
    python3 scripts/manual-pictures.py --lang fr --only home,search-form

Verbinal must be running with Allow external AI agents on, and the person allows the
session this script starts. Target names in the shot list are the English labels;
for French they are looked up in Localizable.xcstrings. Needs Pillow.
"""
import argparse
import base64
import io
import json
import os
import subprocess
import sys
import threading
import time

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, 'docs', 'manual', 'pictures.json')
IMAGES = os.path.join(ROOT, 'docs', 'manual', 'images')
PIXELS_PER_POINT = 1.06     # every picture at one scale: the main window is about 1600 px wide
SIZE_LIMIT = 390 * 1024     # the coverage check allows 400 KB
BANNER_SECONDS = 4          # the "AI agent is working…" banner lingers 3 s after a call


class Spawned:
    """A session of our own: `Verbinal mcp`, over stdio."""

    def __init__(self, app):
        self.proc = subprocess.Popen([os.path.join(app, 'Contents', 'MacOS', 'Verbinal'), 'mcp'],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        self.answers, self.lock, self.next = {}, threading.Condition(), 0
        threading.Thread(target=self._read, daemon=True).start()
        self._request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                     'clientInfo': {'name': 'manual-pictures', 'version': '1.0'}})
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def _send(self, message):
        self.proc.stdin.write((json.dumps(message) + '\n').encode())
        self.proc.stdin.flush()

    def _read(self):
        for raw in self.proc.stdout:
            message = json.loads(raw)
            if 'method' in message and 'id' in message:      # the server asks (ping)
                self._send({'jsonrpc': '2.0', 'id': message['id'], 'result': {}})
            elif 'id' in message:
                with self.lock:
                    self.answers[message['id']] = message
                    self.lock.notify_all()

    def _request(self, method, params, wait=300):
        with self.lock:
            self.next += 1
            rid = self.next
        self._send({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params})
        with self.lock:
            if not self.lock.wait_for(lambda: rid in self.answers, timeout=wait):
                sys.exit(f'No answer to {method} in {wait} s')
            return self.answers.pop(rid)

    def call(self, tool, arguments):
        return self._request('tools/call', {'name': tool, 'arguments': arguments})


class Held:
    """A session another helper holds: JSON lines into DIR/in, answers in DIR/resp-<id>.json."""

    def __init__(self, folder):
        self.folder = folder

    def call(self, tool, arguments, wait=300):
        rid = f'pic{time.time_ns()}'
        with open(os.path.join(self.folder, 'in'), 'w') as fifo:
            fifo.write(json.dumps({'id': rid, 'name': tool, 'arguments': arguments}) + '\n')
        path = os.path.join(self.folder, f'resp-{rid}.json')
        for _ in range(wait * 10):
            if os.path.exists(path):
                with open(path) as f:
                    return json.load(f)
            time.sleep(0.1)
        sys.exit(f'No answer to {tool} in {wait} s')


def text_of(answer):
    """The first text block of a tool's answer, as JSON when it is."""
    if 'error' in answer:
        sys.exit(f'Tool error: {answer["error"]}')
    for block in answer['result'].get('content', []):
        if block.get('type') == 'text':
            try:
                return json.loads(block['text'])
            except ValueError:
                return block['text']
    return None


def french_labels():
    with open(os.path.join(ROOT, 'Verbinal', 'Resources', 'Localizable.xcstrings'), encoding='utf-8') as f:
        strings = json.load(f)['strings']
    out = {}
    for key, entry in strings.items():
        unit = entry.get('localizations', {}).get('fr', {}).get('stringUnit')
        if unit:
            out[key] = unit['value']
    return out


def localized(value, labels, key=None):
    """Targets named by their English label, in the app's language; {"en": …, "fr": …} as the run's."""
    if isinstance(value, dict):
        if set(value) == {'en', 'fr'}:
            return value['fr' if labels else 'en']
        return {k: localized(v, labels, k) for k, v in value.items()}
    if isinstance(value, list):
        return [localized(v, labels, key) for v in value]
    if isinstance(value, str) and value.startswith('='):
        return value[1:]                      # a name the app never translates: a sheet's, a popover's
    if isinstance(value, str) and key in ('target', 'contains') and labels:
        return labels.get(value, value)
    return value


def personal_terms(session):
    auth = text_of(session.call('get_auth_state', {}))
    if not isinstance(auth, dict) or not auth.get('isAuthenticated'):
        sys.exit('Sign in to Verbinal first: the manual shows the signed-in screens.')
    return [t for t in (auth.get('displayName'), auth.get('username')) if t]


def boxes(session, words, fields=()):
    """Where the words show, and the named fields, whose values the listing does not give."""
    found = []
    for word in words:
        listing = text_of(session.call('list_ui_targets', {'kind': 'all', 'contains': word, 'limit': 500}))
        found += [t['at'] for t in (listing or {}).get('targets', []) if t.get('at')]
    for name in fields:
        listing = text_of(session.call('list_ui_targets', {'kind': 'all', 'contains': name, 'limit': 500}))
        found += [t['at'] for t in (listing or {}).get('targets', [])
                  if t.get('at') and t.get('name') == name and t.get('kind') in ('textField', 'secureField')]
    return found


def ring(session, shot, labels):
    """Ring each callout's target in the app; answer where each is, in points, in order."""
    callouts = [c if isinstance(c, dict) else {'target': c} for c in shot.get('callouts', [])]
    if not callouts:
        return []
    if any('help' in c for c in callouts):
        # A control named after the person (the account menu) is found by its tooltip.
        listing = text_of(session.call('list_ui_targets', {'limit': 500}))
        by_help = {t.get('help'): t['id'] for t in listing.get('targets', []) if t.get('help')}
        for c in callouts:
            if 'help' in c:
                c['target'] = by_help.get(labels.get(c['help'], c['help']), c['help'])
    hints = [{'target': localized(c, labels)['target'], 'style': 'ring'} for c in callouts]
    shown = text_of(session.call('show_ui_hints', {'mode': 'replace', 'untilClosed': True, 'hints': hints}))
    if shown.get('missing'):
        print(f'  {shot["name"]}: no callout target for {[m.get("target") for m in shown["missing"]]}')
    placed = []
    for callout, hint in zip(callouts, shown.get('shown', [])):
        listing = text_of(session.call('list_ui_targets', {'kind': 'all', 'contains': hint['id'], 'limit': 50}))
        at = next((t['at'] for t in listing.get('targets', []) if t.get('id') == hint['id']), None)
        if at:
            placed.append((at, callout.get('at', 'corner')))
    return placed


def badge(draw, number, rect, where, font):
    """A numbered badge by the ringed element: at its top-right corner, or above, below, left, right."""
    x, y, w, h = rect
    radius = 13
    cx, cy = {'corner': (x + w, y), 'above': (x + w / 2, y - radius - 4),
              'below': (x + w / 2, y + h + radius + 4), 'left': (x - radius - 4, y + h / 2),
              'right': (x + w + radius + 4, y + h / 2)}[where]
    draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=(10, 132, 255),
                 outline=(255, 255, 255), width=2)
    draw.text((cx, cy), str(number), fill=(255, 255, 255), font=font, anchor='mm')


def shoot(session, shot, lang, labels, private):
    session.call('clear_ui_hints', {})
    proposals = []
    for tool, arguments in shot.get('steps', []):
        answer = text_of(session.call(tool, localized(arguments, labels)))
        if isinstance(answer, dict) and answer.get('missing'):
            missing = [m.get('target', m) if isinstance(m, dict) else m for m in answer['missing']]
            print(f'  {shot["name"]}: {tool} found nothing for {missing}')
        if isinstance(answer, dict) and answer.get('proposalID') and not answer.get('applied'):
            proposals.append(answer['proposalID'])   # an example that waits in Pending
    callouts = ring(session, shot, labels)
    time.sleep(shot.get('settle', 0) + BANNER_SECONDS)

    answer = session.call('capture_view', {'maxPixels': 2048})
    picture, frame = None, None
    for block in answer['result'].get('content', []):
        if block.get('type') == 'image':
            picture = Image.open(io.BytesIO(base64.b64decode(block['data']))).convert('RGB')
        elif block.get('type') == 'text':
            frame = json.loads(block['text'])
    if picture is None:
        sys.exit(f'{shot["name"]}: no picture: {frame}')
    scale = picture.width / frame['points']['width']

    pad = 3
    fields = [localized({'target': f}, labels)['target'] for f in shot.get('blurFields', [])]
    rects = boxes(session, private + shot.get('blur', []), fields) + shot.get('blurRects', [])
    if 'blurRows' in shot:
        # A list of the person's own files: only the rows the picture is about stay readable.
        ax, ay, aw, ah = shot['blurRows']['within']
        keep = tuple(shot['blurRows'].get('keep', []))
        listing = text_of(session.call('list_ui_targets', {'kind': 'all', 'limit': 500}))
        rects += [t['at'] for t in listing.get('targets', [])
                  if t.get('kind') == 'row' and t.get('at')
                  and ax <= t['at'][0] and t['at'][0] + t['at'][2] <= ax + aw
                  and ay <= t['at'][1] and t['at'][1] + t['at'][3] <= ay + ah
                  and not t.get('name', '').split(', ')[0].lower().endswith(keep)]   # "name, size"
    for x, y, w, h in rects:
        box = tuple(round(v * scale) for v in (x - pad, y - pad, x + w + pad, y + h + pad))
        region = picture.crop(box)
        small = region.resize((max(1, region.width // 12), max(1, region.height // 12)))
        picture.paste(small.resize(region.size).filter(ImageFilter.GaussianBlur(6)), box)

    left, top = 0, 0
    if 'crop' in shot:
        left, top, w, h = shot['crop']
        picture = picture.crop(tuple(round(v * scale) for v in (left, top, left + w, top + h)))
    factor = PIXELS_PER_POINT / scale
    picture = picture.resize((round(picture.width * factor), round(picture.height * factor)), Image.LANCZOS)

    if callouts:
        draw = ImageDraw.Draw(picture)
        try:
            font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 15)
        except OSError:
            font = ImageFont.load_default()
        for number, ((x, y, w, h), where) in enumerate(callouts, 1):
            rect = ((x - left) * PIXELS_PER_POINT, (y - top) * PIXELS_PER_POINT,
                    w * PIXELS_PER_POINT, h * PIXELS_PER_POINT)
            badge(draw, number, rect, where, font)

    folder = os.path.join(IMAGES, lang, shot['chapter'])
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, shot['name'] + '.png')
    picture.save(path, optimize=True)
    if os.path.getsize(path) > SIZE_LIMIT:
        picture.quantize(colors=256, method=Image.Quantize.FASTOCTREE,
                         dither=Image.Dither.NONE).save(path, optimize=True)
    for tool, arguments in shot.get('after', []):
        session.call(tool, localized(arguments, labels))
    for proposal in proposals:
        session.call('withdraw_proposal', {'id': proposal})
    print(f'  {os.path.relpath(path, ROOT)}  {picture.width}×{picture.height}  '
          f'{os.path.getsize(path) // 1024} KB')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--lang', choices=('en', 'fr'), required=True)
    parser.add_argument('--only', help='comma-separated picture names')
    parser.add_argument('--app', default='/Applications/Verbinal.app')
    parser.add_argument('--held', metavar='DIR', help='use a session another helper already holds')
    parser.add_argument('--private', action='store_true', help="blur the signed-in person's name and username")
    args = parser.parse_args()

    with open(SHOTS, encoding='utf-8') as f:
        shots = json.load(f)['pictures']
    if args.only:
        wanted = set(args.only.split(','))
        shots = [s for s in shots if s['name'] in wanted]

    if args.held:
        session = Held(args.held)
    else:
        session = Spawned(args.app)
        print('Allow the session in Verbinal…')
        started = text_of(session.call('start_session', {
            'agent': 'manual-pictures', 'model': 'a script',
            'purpose': 'Take the user manual\'s pictures: it moves between screens, opens and closes '
                       'panels and captures the window. It changes none of your data.'}))
        if not isinstance(started, dict) or 'session' not in started:
            sys.exit(f'The session was not allowed: {started}')

    labels = french_labels() if args.lang == 'fr' else {}
    landing = text_of(session.call('navigate_to', {'mode': 'landing'}))
    tiles = text_of(session.call('list_ui_targets', {'screen': 'landing'}))
    names = {t.get('name') for t in tiles.get('targets', [])}
    if localized({'target': 'Portal'}, labels)['target'] not in names:
        sys.exit(f'Verbinal is not in {args.lang}: set Settings ▸ General ▸ Language first. ({landing})')

    private = personal_terms(session) if args.private else []
    print(f'{len(shots)} picture(s), in {args.lang}:')
    for shot in shots:
        shoot(session, shot, args.lang, labels, private)
    session.call('clear_ui_hints', {})


if __name__ == '__main__':
    main()
