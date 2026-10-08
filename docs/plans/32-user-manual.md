# Plan 32 — The user manual (Verbinal 1.4.0)

**Date:** 2026-10-07
**Branch:** a new branch `docs/user-manual` from `main` (1.4.0 released at `9c8f1b1`)
**Audience of the manual:** someone new to Verbinal: an astronomer who knows CADC or CANFAR a little, or
not at all, and has never opened the app.

**Reviewed by the person on 2026-10-07.** Their decisions are at the end and are built in below.

## Goal

One manual, in English and French, that covers **everything a person can do in Verbinal 1.4.0**: every
screen, sheet, panel, menu, shortcut and setting. It is written as tasks ("How to cut out a region") with
the reference beside them. Nothing in it is from memory: each claim is checked against the code. A
coverage check fails when a screen, setting, menu item or shortcut has no page, or when the English and
French disagree in shape.

**The manual is outside the app.** It lives in this repository, not in the app bundle. Writing it changes
no app code and no app tests, and needs no release. Help ▸ Verbinal Help (⌘?) already opens the GitHub
README, so a link at the top of the README reaches the manual.

Not in scope:
- the iOS port, which is not published;
- how to work on Verbinal's code (`CONTRIBUTING.md`);
- the MCP tools one by one. Assistants have `man`, `describe_app` and `AGENTS.md`. The manual explains
  what the *person* sees and decides when an assistant works with them.

## What "100%" is — the inventory

Taken from the code on 2026-10-07, and checked again at step A:

| What | Count | Source |
|---|---|---|
| Screens | 10: Home, Search, Portal, Research, Storage, FITS Viewer, Cube Viewer, Remote Compute, Workflows, AI Guide | `AppMode` |
| App-wide sheets | 7: Sign In, About, Export All, Pending (agent proposals), What Verbinal Can Do, Welcome, Connect an AI Agent | `AppState.ActiveSheet` |
| Settings sections | 8: General, Portal, AI Agent, Image Discovery, AI Compute, MCP Clients, Endpoints, About | `SettingsSection` |
| Menus | File (Export All…), Go (8 screens + Image Discovery…), View (zoom), Help (4 items) | `VerbinalApp.swift` |
| Keyboard shortcuts | about 40 | `.keyboardShortcut` across the app |
| Around every screen | the account menu, the toolbar, the activity bar, the file browser panel (⌘B), Pending, notifications, the Home tiles (Addons too) | `ContentView`, `LandingView` |
| Every interaction, screen by screen | 17 areas, about 250 rows | `docs/agent-ui-parity.md`, whose "UI interaction" column lists what a person can do |
| Every word on screen | 1,864 strings, 1,814 in French | `Localizable.xcstrings`: the exact labels the manual quotes, in each language |

The QA handout [29](./29-qa-full-app-validation.md) walked the same ground for an assistant; its cases
are a checklist for the chapters.

## Principles

- **The code is the source.** Read the view before writing about it. Quote labels exactly as the string
  catalogue has them in that language, in **bold**, with ▸ for paths (**Settings ▸ AI Agent**,
  **Réglages ▸ Agent IA**). The French manual quotes the French labels, never translations of the
  English ones.
- **Tasks first, reference after.** Each chapter: what it is for, what it needs (sign-in or not), the
  tasks step by step, then every control, tips, and what can go wrong.
- **One owner per topic (DRY).** The manual is the user-facing source. The README links to its chapters
  instead of repeating them. AGENTS.md stays the source for connecting a client; the manual links to it.
- **Plain words.** Second person, short sentences, the person's words ("files on this Mac", not
  "local URLs"), a glossary for the astronomy and platform terms.
- **The two languages move together.** A chapter is done when it is written in both, with the same
  headings, steps and pictures in the same order. A change to one is a change to both, in one commit.
- **What an assistant can do here.** A chapter ends with one line on what an AI assistant can do on that
  screen, linking to the AI chapter. The manual does not list tools.
- **Findings are logged, not fixed here.** Writing the manual will find rough edges in the app. They go
  in a findings list (below), each to be changed later in the app, not in this plan.

## The manual

```text
docs/manual/
  README.md             the way in: one line per language
  COVERAGE.md           every area of the app → the chapter and heading that covers it
  en/  00-contents.md … 16-troubleshooting.md, a-shortcuts-and-menus.md, b-glossary.md
  fr/  the same file names, in French
  images/en/<chapter>/  pictures of the app in English
  images/fr/<chapter>/  the same pictures, taken with the app in French
```

| # | Chapter | Covers |
|---|---|---|
| 0 | Contents | What Verbinal is, who it is for, how to read the manual |
| 1 | Getting started | Install (Mac App Store, GitHub), requirements (macOS 14, Apple silicon and Intel), what works without an account, first launch and Welcome, Home and its tiles, the window (toolbar, account menu, activity bar, file browser ⌘B, Pending), signing in and out, getting around (Go menu, ⌘1…⌘8), the language setting, Help menu, What Verbinal Can Do |
| 2 | Search the CADC archive | The form: target and name resolver, position and Radius, time, spectral range, the data train; Search (⌘↩), Reset, Cancel; results: columns, sort, filter, units, selection, previews, observation detail, data links, download, export; the ADQL editor and its checks; VizieR; history and saved queries |
| 3 | Research | Keeping observations with or without files, cutouts, notes, ratings, tags, search, Spotlight, opening in the viewers, Export All and bundles (no import from this Mac: it was never built) |
| 4 | FITS Viewer | Opening (recent files, drag, Research, Storage, the file browser), tabs, stretch, colour maps, cuts, zoom and fit (View menu), North Up, WCS readout and the probe, headers, multi-extension and fpack, blink and linked tabs, bookmarks, marks (draw, edit, DS9 export), spectra (x1d), figures of the image or a region |
| 5 | Cube Viewer | Opening a cube, slice mode, volume mode and the camera, spectrum at a pixel, channel profile, marks, figures, the Intel note |
| 6 | Portal: sessions | Platform load, session cards (CPU, RAM, GPU), the launch form (types, images, flexible or fixed resources, searching long lists, the registry), launch progress, opening, renewing and deleting, events and logs, recent launches, notifications |
| 7 | Portal: batch jobs | Headless jobs: submitting, following thousands, filters on every tab, the history kept after CANFAR drops a job |
| 8 | Image Discovery and the registry | Finding the image that has your packages; the probe job and what it costs; the registry browser |
| 9 | Storage (VOSpace) | Browsing, upload, download, folders, delete (a folder with everything in it), the sensitive-file warning, quota (no rename or move in the app) |
| 10 | Remote Compute | What it is, choosing the image (**Settings ▸ AI Compute**), starting and stopping, running code, runs and their output, "not ready", what survives quitting |
| 11 | Workflows | Templates, copying, following steps, editing and deleting your own, add-on steps |
| 12 | Working with an AI assistant | What MCP is and what stays private; connecting (the wizard for Claude Desktop and Claude Code, other clients through AGENTS.md, **MCP Clients**); allowing a session and giving it instructions; what it may do without asking, kind by kind; Pending: reviewing, applying, the why; hints and the dimmed window; the activity bar; the session log and Diagnostics |
| 13 | AI Guide | What every assistant is told: guide tools, standing rules, tool descriptions; why changes here always wait for you |
| 14 | Settings | Every section and every setting in it, one table each |
| 15 | Privacy and your data | What is kept where (Keychain, the database, Downloads, caches), what leaves the Mac and to whom, no telemetry, removing your data |
| 16 | Troubleshooting | Sign-in, CANFAR slow or down, compute not ready, an assistant that cannot connect, the Intel cube banner, Diagnostics, Report an Issue |
| A | Keyboard shortcuts and menus | Every menu item and shortcut |
| B | Glossary | CADC, CANFAR, Skaha, VOSpace, CAOM, ADQL, TAP, WCS, HDU, cube, MCP, … |

Roughly 25,000–35,000 words in each language, and 45–60 pictures in each.

### Pictures

- Captured from the person's running app with Verbinal's own `capture_view`, while they are signed in.
  Every picture is then the window exactly as the person sees it, at one window size and in one
  appearance.
- Callouts: the app rings each target (`show_ui_hints`), and the script numbers the rings, so a
  picture can carry ①②③ that the text refers to. The app's own numbers do not show in a capture.
- `scripts/manual-pictures.py` takes them from `docs/manual/pictures.json`, a shot list that can be
  run again in either language when the app changes.
- **The person's account may show** (their word, 2026-10-07): their name in the toolbar and on the
  account menu. Nothing else personal: no email, no passwords or secrets, and no other person's names
  or files. Check every picture before it is committed. `--private` blurs the name and username, for a
  re-shoot on another account.
- English first, then the same list again with the app switched to French in **Settings ▸ General**
  (a relaunch, and a new assistant session to allow).
- PNG, 2× resolution, under 400 KB each.

### Coverage check

`scripts/manual-coverage.py`, run by `ci.yml` as its own step. It sits outside the app, like the manual:
it reads the app's sources and the manual and changes neither. It fails when:

- a screen (`AppMode`) has no chapter;
- a Settings section, an app-wide sheet, a menu item or a keyboard shortcut is not named in the chapter
  that should have it. Labels are looked up in `Localizable.xcstrings`, English in `en/`, French in `fr/`;
- an area (`## `) of `docs/agent-ui-parity.md` has no row in `COVERAGE.md`, or a row points at a heading
  that does not exist;
- `en/` and `fr/` differ in files, in their number of headings and steps, or in the pictures they use;
- a relative link or a picture does not resolve.

A new screen, setting or shortcut in the app then fails CI until the manual has it in both languages,
as the parity test does for tools.

## Steps

| Step | What | State |
|---|---|---|
| **A** | Inventory, checked against the code: `COVERAGE.md` mapping every parity area, screen, sheet, setting, menu item and shortcut to a chapter | done `613990d` |
| **B** | The skeleton in both languages, `scripts/manual-coverage.py` in CI (red first: 196 problems), and `scripts/manual-pictures.py` with its shot list | done `613990d` |
| **C** | Chapters 0, 1, 12, 13, 14 | done `fb635b0` (1), `9be3c84` (12), `7b6900e` (13, 14), `fa45d27` (0) |
| **D** | Chapters 2, 3 | done `8851bfc`, `eba635e` |
| **E** | Chapters 4, 5 | done `0799096`, `ed634c8` |
| **F** | Chapters 6–9 | done `c534d74`, `3119c4e`, `cf5151b` |
| **G** | Chapters 10, 11, 15, 16, A, B | done `2ed4715`, `c79f230`, `3547ef4`, `fa45d27` |
| **P** | Pictures: 49 in each language | done: French in this session, English `495b588`, the English Storage picture retaken after Storage listed again |
| **L** | README's top links the manual in both languages; `docs/MCP-Setup.md` and AGENTS.md link chapter 12 | done `80e26ed` |
| **R** | [Handout 33](./33-manual-review.md): a new-user pass in each language | handout written `e36dd45`; the pass is the reviewer's |
| **W** | The website: GitHub Pages at https://szautkin.github.io/canfar-macos/, built from `docs/manual` by MkDocs Material (`mkdocs.yml`, pinned in `.github/manual-requirements.txt`) on every push to main (`.github/workflows/manual-site.yml`), after the coverage check; `scripts/manual-llms.py` adds `llms.txt`, `llms-full.txt` and a Markdown copy of each page for agents | built and checked here; live once merged and Pages is set to GitHub Actions |

Each chapter is written in both languages in the same commit, with the coverage check green for what is
written.

## Findings so far (for the app, not this plan)

Found while writing the manual against 1.4.0 (build 17). Each is its own change later.

**Navigation and help**
- The **Go** menu has no Remote Compute, and calls Home "Landing".
- **What Verbinal Can Do** has no Cube Viewer, Portal, Remote Compute or Workflows entry.
- **Verbinal Help** (⌘?) opens the GitHub README. That works with the README's link to the manual, but
  the manual's own address, https://szautkin.github.io/canfar-macos/, would be a better target.
- ⇧⌘E is bound twice: **File ▸ Export All…** and the Search results' **Export** menu.
- The Welcome sheet says the assistant has "~60 tools"; it has about 210.

**French**: shown in English, or mistranslated, in the French app
- Settings: the Portal tab's footnotes, the AI Agent tab's MCP Server footnote, the MCP Clients
  diagnostics (each check and its detail), the Endpoints groups, service names and the **Default** /
  **Resolved** badges.
- AI Guide: the header's counts ("213 tools", "16 categories") and every area's title and description.
- Search: the **Results (N)** tab.
- Export Data: the module names **Research** and **Search**.
- Session Logs: the **Open** badge of a live session reads "Ouvrir" (the verb).
- "Filter" as a column or field name reads "Filtrer" (the verb): the data train's column, and
  Research's metadata.
- The observation detail's **Enregistrer dans Recherche** is cut short ("Enregistrer da…").

- FITS Viewer: Blink's image **B** button reads "G" (it shares its catalogue key with the Marks panel's
  bold button, gras); the **Marques** button is cut short ("Marq…").
- Cube Viewer: **Slice** / **Volume**, the **Dark** / **Black** / **Light** backgrounds and the
  **Resident** / **Streamed** mode are in English; "Faible" wraps onto two lines; the guide's "Keys"
  reads "Clés" (it should be "Touches").
- Portal: the images card's **Default** and **Popular** chips; Image Content Discovery's "Discovered …
  of … images".

**Other**
- An assistant cannot open the FITS Viewer's **Header**, **Bookmarks** or **Marks** panels: they are
  plain buttons, not openers `open_ui` knows.
- Pointing at a control in the FITS Viewer's side panel can scroll the panel sideways, and it stays cut
  off until the screen is opened again.
- Storage: opening a folder while the previous listing is still loading shows the earlier listing under
  the new folder's path, with a "cancelled" banner, until Storage is opened again.
- Storage has no rename or move; plan 32's outline listed them, and the manual leaves them out.
- Storage: leaving the screen while a folder loads cancels the load, and coming back does not start it
  again; after that every folder answers "cancelled" until **Retry** is pressed or Verbinal restarts.
- Remote Compute: the status and the size banner show 1.07 GB as "1." ("1. Go", "has 1. of the 8 GB");
  the banner is half English in French; the setup text still speaks of "auto-apply", which the per-kind
  settings of 1.4 replaced.
- Workflows: the sidebar is narrow enough to cut every name short; **New Workflow** sits in the
  toolbar's overflow (») at a normal window size; the selected workflow's title sits under the toolbar,
  blurred; the steps keep the last workflow's scroll position when another is selected.
- `capture_view` leaves out popovers (Activity, Columns, a result's preview): they are windows of their
  own. The manual describes them without pictures.
- The App Store description and the README speak of VizieR cone searches in the app; in the app VizieR
  is a name resolver, and the cone search is an assistant tool.
- Research's observations are in Spotlight, but choosing a result only opens Verbinal: nothing shows the
  observation.
- CHANGELOG 1.3.4 lists a "Research local FITS import" that was never built.

## Decisions (the person, 2026-10-07)

1. **Where it lives:** outside the app. Markdown in this repository, `docs/manual/`, reached from the
   README. No app change.
2. **Languages:** English and French together, chapter by chapter.
3. **Pictures:** captured from the person's account through Verbinal. Later the same day: their account
   (their name) may show.
4. **Publishing (2026-10-08):** on GitHub: GitHub Pages, at the repository's address, with `llms.txt`
   for agents.
