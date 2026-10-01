# QA handout — regression pass for plan 27 (every element on screen; hints)

**Date:** 2026-10-01
**Build:** `release/1.4.0` at the plan 27 W commit or later. `describe_app` must say `serverVersion: "1.4.0"`;
record its `buildCommit`.
**Audience:** the MCP QA pass (an assistant connected to Verbinal), with the person watching the screen. ~1½
hours. Go slowly: each hint stays long enough to be seen, and the person says what they saw.
**Related:** [Plan 27](./27-ui-targets-and-hints.md) · [Handout 26](./26-qa-regression-plan25.md)

This pass checks what plan 27 built:

- every element on screen, from the accessibility tree — controls, list entries, text;
- hints: one or many, placed with no overlaps, kept off images, brought into view;
- selecting a list's entry; opening a closed section, panel or menu on purpose;
- hints are not marks.

Record each case as **PASS / FAIL / BLOCKED**, with the tool's JSON and what the person saw for a FAIL.

**Before you start:**

- The Mac's screen stays unlocked: while it is locked, macOS answers nothing about any window, and
  every tool says so (`problem`).
- Sign in to CADC. Start the session (`start_session`); the person clicks Allow.
- Hints never press anything, but `select_ui` and `open_ui` change what is shown: say what you are
  about to do.

---

## 1. Every element

| # | Steps | PASS if |
|---|---|---|
| 1.1 | `list_ui_targets` on Landing. | Every control, `unnamed: 0`; the tiles have `stable: true` ids (`home.search`, `home.portal`, …). |
| 1.2 | `list_ui_targets` on each of Search (its three tabs), Portal, Remote Compute, Storage, Research, FITS Viewer, Cube Viewer, Workflows, AI Guide. | `unnamed: 0` on each; `window.screen` names the screen. |
| 1.3 | `kind: "all"` on Search. | More than with the default: text, images and areas too. |
| 1.4 | Portal: `includeScrolled: true`, `contains: "Relaunch"`. | Each Recent Launches card is an `item` named by its launch; each Relaunch and Remove has `item` and an id with the card's name; those below the fold have `inSight: false`. |
| 1.5 | Search: `includeScrolled: true`; look at Recent Searches and Saved Queries. | Each entry is an `item`; its Load / Run / Remove name it. |
| 1.6 | Storage. | Each file is one entry named by the file. |
| 1.7 | The person opens the Batch Jobs modal, then the Images modal (Image Discovery); `list_ui_targets` on each. | `window` is the sheet; each job / image is a `row`, its buttons named with it. |
| 1.8 | `open_settings` `agent`; `list_ui_targets` `includeScrolled: true`. | The window is Settings; the switches out of sight are listed `inSight: false`. |

## 2. One hint, and many

| # | Steps | PASS if |
|---|---|---|
| 2.1 | Landing: `point_at_ui` `home.search` with a message, 10 s. | A ring and a bubble with a tail touching the tile; it goes after 10 s. |
| 2.2 | `point_at_ui` `Portal` (by name) right after. | Both hints are up: each call adds. |
| 2.3 | `show_ui_hints`, `numbered: true`, `dim: true`, five tiles, `untilClosed: true`. | Bubbles 1–5, none overlapping each other or a tile; the window dimmed except the tiles. They stay until the person closes them. |
| 2.4 | The person hovers a bubble with seconds set, then moves off. | Its countdown waits while hovered. |
| 2.5 | The person presses Esc. | Every hint goes. `list_events` has `hintsDismissed`, `how: "escape"`. |
| 2.6 | `show_ui_hints` `all: {}` on Portal. | A ring round every control; `as: "ring"` for each. `clear_ui_hints` takes them all down. |
| 2.7 | Portal: four hints with text on one session card's Open, Renew, Events, Delete. | Four bubbles placed round neighbouring buttons, none overlapping. |
| 2.8 | Twenty hints with text at once. | Twelve bubbles; the rest in the numbered hint list, their elements badged with their numbers; nothing overlaps. |
| 2.9 | With hints up, `list_ui_targets`. | The screen's controls, never the bubbles. |
| 2.10 | `navigate_to` another screen with hints up. | The hints go (`screenChanged`). |
| 2.11 | `point_at_ui` `nothing like this`. | `pointed: false`, with `candidates`, and `closed` naming closed pop-ups it may be behind. |
| 2.12 | Search: `point_at_ui` `Load SN 2023ixf` when several recent searches share that name. | Refused: two equal matches is a question — even when only one is showing. |

## 3. Brought into view

| # | Steps | PASS if |
|---|---|---|
| 3.1 | Settings ▸ AI Agent scrolled to its middle: `point_at_ui` `settings.agent.allowExternal`. | Settings scrolls up; the hint is on the switch. |
| 3.2 | Then `point_at_ui` `Show Session Logs…`. | It scrolls down to it. |
| 3.3 | `show_ui_hints` on the first switch and on Show Session Logs… together. | One shown; the other in `missing` with `reason`: they do not fit in sight together. |
| 3.4 | Portal: `point_at_ui` `Relaunch notebook1` (below the fold of Recent Launches). | The list inside the page scrolls; the hint is on that card's Relaunch; the answer's `id` is its id now. |
| 3.5 | Search: the 30th Load in Recent Searches, by its id from 1.5. | It scrolls into view and is pointed at. |
| 3.6 | Storage: a folder far down, by name. | It scrolls into view. |

## 4. Selecting, and opening on purpose

| # | Steps | PASS if |
|---|---|---|
| 4.1 | Storage: `select_ui` a file by name. | It is selected as a click selects it; Download and Delete enable. Nothing is downloaded or deleted. |
| 4.2 | Research: `select_ui` a downloaded observation. | It is selected; its detail shows. |
| 4.3 | Portal: `select_ui` a Recent Launches card. | `selected: false`: these entries act through their buttons. Nothing is launched. |
| 4.4 | `select_ui` `search.run`. | `selected: false`: a button is never pressed. No search runs. |
| 4.5 | `open_ui` `file browser`, then `close_ui` it. | The file browser opens, `inside` lists what appeared; it closes. |
| 4.6 | Research: `open_ui` a collapsed collection (`closed: true`). | It opens; `inside` lists its observations. `close_ui` folds it again. |
| 4.7 | Search: `open_ui` the `Preset` pop-up. | The menu opens and waits (`waiting: true`); `list_ui_targets` lists its items; `point_at_ui` on one draws above the menu. The person presses Esc, or `close_ui` closes it. Nothing is chosen. |
| 4.8 | `open_ui` `ADQL` (a tab). | Refused, naming `set_search_tab`. |

## 5. Hints are not marks; the window

| # | Steps | PASS if |
|---|---|---|
| 5.1 | With a FITS file open and a mark on it: `show_ui_hints` on the viewer's controls. | Bubbles sit beside the image where there is room; the mark stays in sight. |
| 5.2 | `clear_ui_hints`. | The mark is still there (`list_fits_annotations`). |
| 5.3 | `clear_annotations` with hints up. | The hints are still up. |
| 5.4 | Open Settings, then close the main window. | Settings closes too; any hints go. |
| 5.5 | Lock the screen; `list_ui_targets`. | `problem` says the screen cannot be read; nothing is listed. |

## Report

For each FAIL: the case, the tool's JSON, a screenshot of what the person saw, and the build commit.
