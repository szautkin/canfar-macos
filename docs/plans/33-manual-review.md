# Handout 33 — Review of the user manual against the app

**Date:** 2026-10-07
**Build:** Verbinal 1.4.0 (17), the Mac App Store release, or `main` at `9c8f1b1` or later.
**Manual:** `docs/manual/` on the `docs/user-manual` branch (plan 32).
**Audience:** someone new to Verbinal, following the manual as a new user would: a person, or an
assistant with the person watching. Each part stands alone; about three hours for one language.
**Related:** [plan 32](./32-user-manual.md), the manual's [contents](../manual/en/00-contents.md).

The manual says what the app does. This pass checks that it is right: that each step works as written,
that each label is the one on the screen, that each picture matches, and that nothing the app does is
missing. Where the manual and the app disagree, the report says where and how; it does not fix either.

Do the pass once in English, and once in French with **Settings ▸ General ▸ Language** set to
**Français** (the French chapters quote the French labels).

Record each case as **PASS / FAIL / BLOCKED / SKIPPED**, with:

- the chapter and heading, and the manual's words that are wrong;
- what the app does instead, with a screenshot when it is about the screen;
- for a missing feature: where it is in the app.

## Ground rules

1. **Follow the manual, not memory.** Do only what the chapter says, in its order.
2. **Signing in is the person's.** Chapters 6 to 10 need a CADC account with CANFAR access.
3. **Allocation and data are the person's.** Ask before launching a session or a batch job, starting
   Remote Compute, probing an image, uploading, deleting, or changing who may read a file. If the answer
   is no, the case is SKIPPED.
4. An assistant doing the pass starts its session first (`start_session`) and follows the person's
   instructions.

## 0. The manual itself

| Case | Check |
|---|---|
| 0.1 | `python3 scripts/manual-coverage.py` says the manual covers the app, in English and French. |
| 0.2 | Every link of [the contents](../manual/en/00-contents.md) opens its chapter; the README's manual links work on GitHub. |
| 0.3 | The pictures render on GitHub, are readable, and show nothing private: no email, no secrets, no other person's names or files. |

## 1. Getting started

| Case | Check |
|---|---|
| 1.1 | On a Mac that has never run Verbinal (or after removing its folder, chapter 15): the Terms of Use, Welcome and notification prompts come as **The first launch** says. |
| 1.2 | Home has the tiles of the table, in that order; signed out, the three that need an account say **Locked** and lead to sign-in. |
| 1.3 | The toolbar's buttons 1–5 are as numbered; the account menu shows email, institute and **Sign Out**. |
| 1.4 | The activity bar and its list, and the file browser (⌘B, Downloads, filter, supported files, **Grant Access…**), as described. |
| 1.5 | Every **Go** item and shortcut of the table. |
| 1.6 | Sign in with and without **Remember me**; sign out. |
| 1.7 | Change the language, restart, change it back. |
| 1.8 | The **Help** menu and **About Verbinal** (**Copy Details**, **Report a Problem**, **Terms of Use**). |

## 2. Search

| Case | Check |
|---|---|
| 2.1 | Search `M101` with the collection CFHT: the resolver, **Radius**, data train cascade and **Cancel** behave as written. |
| 2.2 | Each field of the four groups takes the example the table gives. |
| 2.3 | Results: pages (⌘[ ⌘]), rows per page, **Export** both ways, **Columns**, sorting, units, ⌘F filters, preview on hover, double-click, the right-click menus. |
| 2.4 | An observation's detail: the five tabs, **Download**, **Save to Research**, **Cut Out…**, **View on CADC**. |
| 2.5 | A cutout: shape, centre, size, **Images**, **Also cut**, the size estimate, **Download Cutout**. |
| 2.6 | ADQL: **Generate from Form**, a deliberate mistake listed and selectable, **Execute** (⇧⌘↩), **Save Query**. |
| 2.7 | Recent searches (load, rename by double-click, remove, filter, clear) and saved queries (run, load, remove). |

## 3. Research

| Case | Check |
|---|---|
| 3.1 | The three ways in (**Download**, **Save to Research**, **Download Cutout**) each give the record described. |
| 3.2 | The list: grouping, row marks, the right-click menu; an observation in Spotlight. |
| 3.3 | Every button of the table, including **Download Again**, **Remove File…** and **Delete** (notes kept). |
| 3.4 | A cutout's record and **Original Observation**. |
| 3.5 | Quality, tags and notes save as you type; the filter finds a word of a note. |
| 3.6 | **Export Data**: modules, **Include downloaded files**, **Export Here**, the bundle's `README.md` and `manifest.json`, **Upload to VOSpace**. |

## 4. FITS Viewer

| Case | Check |
|---|---|
| 4.1 | Each way of opening a file; **Open as…** for a cube; tabs (⌘T, ⌘W). |
| 4.2 | Stretch, colour map, cuts and **Auto**; **WCS approximate** on a file without standard WCS. |
| 4.3 | Zoom buttons, **North Up**, the View menu shortcuts, the trackpad, the zoom field, the bar under the image. |
| 4.4 | Crosshair (**Copy**, **Clear**, **Search Here**), **Go To**, **Header**, **Bookmarks**. |
| 4.5 | Two tabs: **Link Crosshair**, **Sync Zoom**, **Blink** and its keys. |
| 4.6 | Marks: each shape, moving, resizing, renaming, styling, the list and filter, **Export**, **Clear All**, the right-click menu. |
| 4.7 | An `x1d` spectrum, and its **Export Figure**. |
| 4.8 | **Export Figure…**: each setting of the table; the file in Downloads. |

## 5. Cube Viewer

| Case | Check |
|---|---|
| 5.1 | Open a cube each way; a very large one says **Streamed**. |
| 5.2 | Slice: the channel strip, keys, pan and zoom, the spectrum probe and inspector, the display settings and R. |
| 5.3 | Volume: turning, zooming, a click jumping to a channel, **Emission** / **Max Intensity**, the sliders, the toggles, the opacity curve. |
| 5.4 | Marks on a channel; figures of the slice and of the volume; the guide. |

## 6–8. Portal, batch jobs, Image Discovery

| Case | Check |
|---|---|
| 6.1 | The three cards and their numbers; the session cards (with **FLEX**, **in use**, GPU when there is one). |
| 6.2 | **Open**, **Renew**, **Events** (events and logs), **Delete** with its question. |
| 6.3 | A launch, step by step, with defaults (stars), **Images cached**, the search in long lists, **Replace** / **Skip**; the progress window and the notification. |
| 6.4 | The **Advanced** tab; the images card's chips, filter, row buttons and links; recent launches. |
| 7.1 | A batch job with two replicas: `REPLICA_ID` and `REPLICA_COUNT` in its environment. |
| 7.2 | **Jobs & History…**: the tabs, the filter, paging, details, events and logs, deleting and stopping, ⌘R, the notifications, **History** and **Clear History**. |
| 8.1 | Image Content Discovery: filters, active filters (⌘⌫), **Use This Image** (↩). |
| 8.2 | A probe: **Discover packages**, the manifest, a failure's details and logs, **Dismiss error**. |
| 8.3 | **Find in Registry…**: search, **Add**, **Your images**, **Remove**. |

## 9–11. Storage, Remote Compute, Workflows

| Case | Check |
|---|---|
| 9.1 | Browsing, the path, sorting, the right-click menu, the quota card. |
| 9.2 | Upload (button and drag), download, a transfer's progress and cancel. |
| 9.3 | **New Folder**; deleting a folder with files in it. |
| 9.4 | A public `.netrc` (made for the test, then removed): the shield, the banner, **Make Private**. |
| 10.1 | Not set up: the steps shown. Set up as the chapter says; **Start Session**. |
| 10.2 | The states, **Stop Session** and its question, the size banner and **Restart with New Settings**. |
| 10.3 | **Run Code** in Python and in Bash; the run's status, code, output, errors, **Copy Code**, **Run Again**; a run that survives quitting. |
| 11.1 | Copy a template, check off steps, the progress, **Overview**. |
| 11.2 | **New Workflow** with the format of the chapter; the warnings; **Edit** and **Delete**. |

## 12–14. The assistant, the AI Guide, Settings

| Case | Check |
|---|---|
| 12.1 | The setup for Claude Desktop and for Claude Code, as written; another client from AGENTS.md. |
| 12.2 | The approval window: each part, editing the instructions for one session, **Deny**, **Allow**. |
| 12.3 | Each kind of the two tables with its default; **Restore Defaults**. |
| 12.4 | **Pending**: a change that waits, its reason, **Apply**, **Reject**, **History**, the three-hour expiry. |
| 12.5 | **Follow agent activity**, the banner, the sound; the activity bar for long work; the badge. |
| 12.6 | Hints: rings, bubbles, numbers, dimming, × and Esc, the time they stay. |
| 12.7 | The session log: list, filters, an entry's requests, export both ways, deleting, **Show in Finder**. |
| 12.8 | What stays the person's: an assistant cannot change a setting or sign in. |
| 13.1 | A guide made, edited and deleted; a description overridden and reset; an assistant's proposal waits. |
| 14.1 | Every row of every table of chapter 14 against its Settings section. |

## 15–16 and the appendices

| Case | Check |
|---|---|
| 15.1 | The table of what is kept where, against the Mac (Keychain, the sandbox folder, Spotlight). |
| 15.2 | Sign out removes the saved password; each **Clear** of the list; removing the app's folder. |
| 16.1 | Each case of troubleshooting that can be made to happen: wrong password, offline launch, an image that cannot be pulled, an assistant with the server off. |
| A.1 | Every shortcut of the appendix, on its screen. |
| B.1 | The glossary's terms are the ones the chapters use. |

## Report

A table of the cases with their outcome, then, for each FAIL, the chapter, the manual's words, what the
app does, and a screenshot. List separately anything the app does that the manual does not mention.
