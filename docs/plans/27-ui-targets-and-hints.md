# Plan 27 — Every element on screen, and many hints on it at once

**Date:** 2026-09-30
**Branch:** `release/1.4.0` (after plan 25, `f8fade7`)
**Asked for** (the person, 2026-09-30):

- "review `list_ui_targets` and related to it functionality"
- "each and every UI element that the user can see on any view, UX that the user can interact with,
  be available to highlight and/or add a popover"
- "add more than one at once, even all on the view"
- "UI/UX items should be able to be outlined, popover with a text added — but not blindly smart, no
  overlaps of popovers"
- "DRY, orthogonality, SOLID, ETC is a must"
- "annotations, aka marks, in the FITS Viewer and Cube Viewer are different things and go along with
  their relevant files … those marks are for images, FITS files and cube files, not for the app's
  UI/UX"

## Status

| Step | State | Commit |
|---|---|---|
| R review and spike | done — this document | |
| A every element, from the accessibility tree | done — `UIElement`, `UIElementRules`, `UIElementSource`, `AXElementSource`, `UIWindowPlaces`, `AppState.screenName`; `.pointable` sets its `vb:` identifier; the tools move onto it in T | d7b53a1 |
| L every element has a name (guardrail) | done — `EveryScreenNamedTests` over every mode, Search tab, Settings section and app-wide sheet; `.pointableArea` for the 14 tags on regions; names for the Search fields, the ADQL query and every `TextEditor` (`textEditorName`, past SwiftUI to the text view); a disclosure called by the words after it | e7b7538 |
| Y the layout: no overlaps, by rules | done — `UIHintLayout` (VerbinalKit): the hard rules, the costs, fewest spots first, the first 12 by the order given, spots kept relative to their element, badges, the hint list; property tests over 200 seeded screens | 4bae863 |
| O the overlay: rings, bubbles, badges, the hint list | done — `UIHintStore`, `UIHintScene`, `UIHintMeasure`, `UIHintTracker`, `UIHintOverlay`, `UIHintPresenter` on `AppState`; the tools move onto it in T | 8db7fc2 |
| T the tools: `show_ui_hints`, `clear_ui_hints`, `point_at_ui`, `list_ui_targets` | done — the registry, anchors and `uiPointerOverlay()` retired; `hintsDismissed` in `list_events`; `screen` and `hints` in `get_current_view`; a window read for the first time is warmed; the overlay never reads as its window; an unreadable screen is said, not listed empty. Checked on the running app too | (this commit) |
| C closed things: `open_ui`, `close_ui` (sections, panels, menus) | not started | |
| V bring into view: scroll | not started | |
| W words, docs, handout 28 | not started | |

---

## Hints are not marks

This plan is about **hints**: the app pointing at its own interface. **Marks** are something else, and
nothing here changes them.

| | **Marks** (FITS Viewer, Cube Viewer) | **Hints** (this plan) |
|---|---|---|
| On | an image: a FITS file's extension, a cube | the app's interface: a button, a field, a row, a panel |
| Pinned to | pixels, sky coordinates, voxels | a UI element, in window points |
| Kept | with their file (`MarkStore`, per file and HDU); reopened with it, exported | never: gone with the screen, never saved, never exported |
| Whose | the person's data: they edit, keep or delete them | transient: the assistant's pointing, which the person closes |
| Tools | `annotate_fits`, `annotate_cube`, `list_fits_annotations`, `list_cube_annotations`, `update_annotation`, `select_annotation`, `remove_annotation`, `clear_annotations`, `export_annotations` | `list_ui_targets`, `point_at_ui`, `show_ui_hints`, `clear_ui_hints` |
| Code | `Verbinal/Marks/` | `Verbinal/UIPointer/`, and `UIHintLayout` in VerbinalKit |

**Rules that keep them apart:**

- **Separate modules,** with no shared types, store or geometry. `UIPointer` does not import or call
  `Marks`, and `Marks` does not import or call `UIPointer`. Mark words ("annotation", "mark",
  "callout", "label", "leader") are not used for hints, in code or in tools, so an assistant never
  confuses the two.
- **A mark is never a UI target.** Marks are drawn on the image canvas, which is hidden from
  accessibility (`MarkOverlay`), so the walk never sees them. The canvas itself is one target. The
  Marks panel's rows and buttons are interface, so they are targets like any other.
- **Hints never touch marks:**
  - `clear_ui_hints` leaves every mark;
  - `clear_annotations` leaves every hint;
  - a hint over a viewer neither moves nor selects a mark.
- **Over an image, hints keep off it.** In the layout, covering a FITS or cube canvas costs more than
  covering anything else, so a bubble sits beside the image when there is room. The marks on it stay
  in sight.
- **The tools say which is which:**
  - `show_ui_hints` and `point_at_ui`: "This points at the interface. To mark something on an image,
    kept with its file, use `annotate_fits` or `annotate_cube`."
  - `annotate_fits` and `annotate_cube` get the reverse.

---

## R — Review: what there is now

### How it works

- **Targets are hand-tagged.** A view calls `.pointable(id, label:, screen:)`. That records a SwiftUI
  anchor and registers the id in `UIPointerRegistry` while the view is on screen.
- **`list_ui_targets`** lists the registry: `id`, `label`, `screen`.
- **`point_at_ui`** matches one target (`UIPointerMatcher`: the id, then the label, then words; two
  equal matches are refused). It sets the registry's one `hint`, and the overlay draws a ring and a
  message for 2–60 seconds.
- **The overlay** is a modifier, `uiPointerOverlay()`, that each window or sheet root must apply.

### What is wrong with it

| # | Finding | Evidence |
|---|---|---|
| 1 | **Most of the screen cannot be pointed at.** There are 66 tags in 21 files. The Search screen shows the person about 160 controls (207, counting rows scrolled out of view); 11 of them are targets. | Spike, below |
| 2 | **Every QA pass found missing targets, each fixed by tagging more by hand.** This never ends, and it drifts: a new control is untargetable until someone notices. | M19/M20 → O1 (plan 15); G9 (plan 17); N2 (plan 21) |
| 3 | **Windows does not tag by hand.** It walks its visual tree: every named control is a target. The Mac diverges from the reference. | `CanfarDesktop/Views/Controls/AgentPointer.cs` `Walk` |
| 4 | **One hint at a time.** A second `point_at_ui` replaces the first. Windows adds one per control. | `UIPointerRegistry.hint` |
| 5 | **No placement.** The message goes below the control, or above it near the bottom edge, clamped sideways. Nothing stops it covering other controls; two of them would overlap. | `PointerOverlayModifier` |
| 6 | **Sheets cannot show a hint** unless their root applies `uiPointerOverlay()`. Five roots do; there are about 40 `.sheet`, `.popover` and `.inspector` sites. | grep |
| 7 | **A hint cannot wait for the person.** It cannot be closed, cannot pause while the person reads it, and nothing tells the assistant it has gone. Windows has `untilClosed`, hover-pause, a close button, and `hintsDismissed` in `list_events`. | Windows `point_at_ui` |
| 8 | **Out of sight is out of reach.** A control scrolled out of view, or inside a closed section, panel or menu, is neither listed nor brought into view, and nothing says it is there. Windows scrolls a control into view and opens closed sections. | Windows `includeCollapsed` |
| 9 | **The listing is thin.** It has no kind (button, field, toggle), no enabled state, no position, and no word on which window or dialog it describes. | `UITargetView` |
| 10 | **Unnamed controls.** 24 of the Search form's text fields have no accessible name. VoiceOver reads "text field", and an assistant has nothing to call them by. | Spike |
| 11 | **Unlocalized labels** on the 8 Remote Compute targets ("Run", "Start Session"). | `RemoteComputeView` |

### The spike (2026-09-30, thrown away after)

- **The accessibility API works on Verbinal's own process:**
  - It needs no Accessibility permission (`AXIsProcessTrusted() == false`, and every call succeeded).
  - It works inside the App Sandbox (a signed test run with the app's entitlements:
    `sandboxed=true`).
- **It sees what the person sees:**
  - every button, toggle, field, pop-up, slider, segment, disclosure, row and text;
  - the toolbar;
  - labels (`AXDescription`, `AXTitle`, `AXTitleUIElement`), tooltips (`AXHelp`), screen frames and
    actions.
  - Search: 411–553 nodes (more once the data train has loaded) in about 55 ms. Landing: 76 nodes.
- **SwiftUI builds its accessibility tree lazily.** The in-process `NSAccessibility` walk saw only
  AppKit-backed controls, and with no labels. The first AX API query wakes the whole tree.
- **Found along the way:**
  - The `.pointable` ids are not accessibility identifiers.
  - SF Symbol names show up as identifiers (`trash`, `gear`).
  - Rows scrolled out of view are in the tree, so they need clipping.
  - A closed `DisclosureGroup` is one disclosure element, and its contents are absent.
  - Scroll-bar parts and window widgets are present, and should not be targets.

**Conclusion:** the accessibility tree is the single source of what is on screen. The app reads its
own, the way VoiceOver does. Hand tags remain only for names that must outlive a language, or a
redesign.

---

## The design

### Principles

- **One source of what is on screen:** the accessibility tree. There is no second registry to keep in
  step with it (DRY), and a new control is a target the day it ships (ETC).
- **It shows; it never acts.** A hint changes no data and presses nothing. The only view changes are
  a scroll to bring a control into view (V), and opening a closed thing when the assistant asks for
  exactly that (`open_ui`, C).
- **Placement by stated rules, not by guessing.** The rules are written below and tested as
  properties, and the same input always lays out the same way.
- **The person stays in control.** Every hint can be closed, Esc clears them all, and nothing waits
  on a clock the person did not ask for.
- **Never in the approval window.** The window where the person allows a session (plan 25) is never
  a target: an assistant must not steer the person's own decision.
- **Hints are not marks** (above).

### The parts, each with one job (SOLID)

| Part | Job | Kind |
|---|---|---|
| `UIElement`, `UIWindowRef` | One thing on screen: a kind, a name, help, enabled, a frame in window points, its window and screen, and whether it is hand-tagged. Never a value typed into a field. | Value types |
| `UIElementSource` (protocol) | "What is on screen now", as a snapshot of elements. | Port |
| `AXElementSource` | Reads the app's own windows through the AX API, and wakes SwiftUI's tree on the first read. macOS only. | Adapter |
| `UIElementRules` | Which elements are targets and which are machinery; the naming chain; visibility (clipped by every scroll area above, at least 4 × 4 pt); ids; exclusions. | Pure functions |
| `UIPointerMatcher` | Which target a name means (kept as it is: id, label, words; two equal matches is a question, not an answer). | Pure, unchanged |
| `UIHintLayout` | Where each bubble goes: the rules below. It knows only rectangles and sizes. | Pure, in VerbinalKit |
| `UIHintStore` | The hints that are up, in sets: add, replace, clear, timers, hover pause, dismissal and its event. | `@Observable`, MainActor |
| `UIHintTracker` | Keeps frames current while hints are up: window moved or resized, a scroll, the screen changed. It snapshots again (debounced) and drops what has gone. | Adapter |
| `UIHintOverlay` | Draws the hints in a transparent child window over each window that has them. The bubbles can be clicked (close, hover); everything else clicks through. | AppKit + SwiftUI view |
| The tools | `list_ui_targets`, `show_ui_hints`, `clear_ui_hints`, `point_at_ui`, all over the same store. `point_at_ui` is `show_ui_hints` with one item. `open_ui` and `close_ui` open and close one closed thing. | MCP |

Dependencies point inward:

- The tools depend on the store and on `UIElementSource`, never on the AX API.
- The layout knows nothing of AppKit.
- Every part is testable with a fake source.
- Nothing in `UIPointer` depends on `Marks`, or the other way round.

### Ids

- **Hand-tagged:** `.pointable("search.run")` now sets the accessibility identifier `vb:search.run`.
  The id is `search.run`, stable across runs, languages and redesigns. These are the ids QA
  handouts, workflows and tours use.
- **`.pointableArea(id, label:)`** names a region ("Spatial constraints", "Column headers"). It
  becomes an accessibility container with that name. Areas are targets too.
- **Every other element** gets a derived id, `screen/kind/name`, with `#2`, `#3` … for repeats in
  reading order, for example `search/textField/RA` and `portal/button/Delete#2`. A derived id holds
  while the screen is as it was listed, in the person's language. The listing says which ids are
  stable (`stable: true`).
- **Not ids:** other accessibility identifiers, such as SF Symbol names.
- **Retired:** the SwiftUI anchors, the registry's target bookkeeping, and every `uiPointerOverlay()`.

### Screens and windows

- An element's `screen` comes from where it is, with no tagging:
  - **The main window:** the view the app is in. This is the same name `get_current_view` gives
    (`search`, `search.results`, `portal`, `fitsViewer`, …), from one function on `AppState` (DRY).
  - **Settings:** `settings.<section>`.
  - **A sheet:** `sheet.<name>`, from `activeSheet`.
  - **An area** names its own part, for example `search.spatial`.
- **The window in front decides the scope by default.** While a sheet or Settings is open, the
  listing and the hints are about that window, as on Windows; `window: "all"` lists every window.
- **Never targets:**
  - the approval window;
  - the overlay windows;
  - marks on an image (hidden from accessibility, above);
  - scroll-bar parts, window widgets and value indicators;
  - elements smaller than 4 × 4 pt, or entirely clipped.

### Names

The first of these that has words:

1. the accessibility description;
2. the title;
3. the title element's text (a slider's or pop-up's caption);
4. the placeholder;
5. the help (the tooltip);
6. the static text just before it, on the same row or directly above. This is the visible caption a
   person reads, the same idea as Windows' `LabeledBy`.

An element with no name after all six is listed with `unnamed: true` and its kind. The step L
guardrail drives that count to zero for interactive elements.

### Kinds

`button`, `toggle`, `textField`, `secureField`, `popUp`, `menuButton`, `segment`, `tab`, `slider`,
`stepper`, `disclosure`, `link`, `row`, `cell`, `image`, `canvas`, `text`, `area`.

- **"interactive"** means every kind except `image`, `canvas`, `text` and `area`.
- **"all"** adds them: everything the person can see. Text is clipped to 120 characters.
- **Values are never read.** The text in a field and the password in a secure field are never read,
  listed or logged.

---

## Y — The layout: no overlaps, by rules

**Words used here:**

- a **ring** goes round an element;
- a **bubble** holds a hint's words, with a **tail** touching its element or a **line** to it;
- a **badge** is a hint's number on its element;
- the **hint list** is a panel of numbered hints.

**Inputs:**

- the window's visible content rectangle;
- each hinted element's frame;
- each bubble's measured size: a title of up to 60 characters, words of up to 280, 160–300 pt wide;
- the frames of the other interactive elements, and of any image canvas, on screen.

**Hard rules.** A placement that breaks one is never used.

1. **Bubbles never overlap each other** (6 pt apart).
2. **A bubble never covers a hinted element,** its own included.
3. **A bubble stays inside the window's visible content.**
4. **Badges never overlap** each other or a hinted element; they are nudged along the element's edge.

**Preferences**, as a cost; the lowest feasible cost wins:

- Covering an element that is not hinted costs by area, so bubbles sit over empty space when there is
  any. Covering a FITS or cube image costs the most, so its marks stay in sight.
- The side with the most room is preferred. Ties go below, then right, then above, then left.
- Nearer the element is better; a bubble away from its element costs more, and so does its line.
- A line that crosses another bubble, or another line, costs more.

**Candidates for each bubble:**

- each side (below, right, above, left) × each alignment (start, centre, end), with a tail;
- then the same sides, slid along the edge in 16 pt steps;
- then a second ring of positions 40 pt out, with a line.

**Order:**

- The hint with the fewest feasible spots is placed first; ties go in reading order (top to bottom,
  then left to right).
- Numbered sets (`numbered: true`) are numbered in the order given, or in reading order when none is
  given.

**When there is no room:**

- The element gets a numbered badge.
- Its words go in the **hint list**, docked to the window side with the most free room. The list
  scrolls when long.
- The list obeys hard rules 2 and 3. If even the list has no room, it shrinks to a pill ("6 hints")
  that opens on hover.
- **At most 12 bubbles show beside their elements;** the rest go to the list. A screen of 50 bubbles
  is not readable, and the person should not have to read it.

**Stability:**

- When frames change (a scroll, a resize), a bubble keeps its spot if that spot is still feasible, so
  bubbles do not jump. Otherwise it is placed again by the same rules.
- The same input gives the same layout, which is tested.

**Rings:**

- A rounded ring, 4 pt outside the element.
- When a hinted area holds hinted controls, the area's ring is dashed, so nested rings do not read as
  one.
- **Dim (`dim: true`)** shades the window except the hinted elements: the spotlight.

---

## O — The overlay

- **One transparent child window per window with hints.** It moves and resizes with its parent, and
  sits above the parent's sheets.
- **Clicks:** the panel ignores the mouse, so clicks reach the app, except while the mouse is over a
  bubble, the hint list or its pill. That is checked 20 times a second while hints are up: a rule the
  code keeps, not a hope about transparent pixels.
- **On each bubble:** a close button (×). Hovering pauses the countdown, and moving off resumes it.
- **Esc clears every hint,** through the app's own key handling, when Verbinal is active.
- **Accessibility and appearance:**
  - VoiceOver announces each new hint's words.
  - Reduce Motion: no animation.
  - Increase Contrast: thicker rings.
  - Light and dark appearances, with the accent colour.
- **How hints go:**
  - after their `seconds`;
  - by their close button;
  - by Esc;
  - by `clear_ui_hints`;
  - when their element is gone after the screen changed;
  - when their window closes.
  
  When the last hint of a set goes, `list_events` gets `hintsDismissed` (Windows' name), with the set
  and how it went, so an assistant can pace a tour by the person's reading.

---

## T — The tools

### `list_ui_targets` (read)

| Argument | Meaning |
|---|---|
| `kind` | `interactive` (default: controls), `text`, `all` |
| `screen` | by prefix, as now |
| `contains` | id or name containing these words (Windows) |
| `window` | `front` (default: the sheet or dialog in front, else the main window), `all` |
| `limit`, `cursor` | 200 at a time |

It answers:

- `window`: its kind and title;
- `targets`: each with `id`, `stable`, `kind`, `name`, `help`, `screen`, `enabled`, and `at` (x, y,
  width, height in window points);
- the closed things on screen among the targets, each with `closed: true` and its kind;
- `unnamed`: a count;
- `next`.

### `show_ui_hints` (view state, new)

| Argument | Meaning |
|---|---|
| `hints` | Up to 100 of `{target, text?, title?, style?: "bubble" \| "ring"}`. Each `target` is matched as `point_at_ui` matches it. |
| `all` | `{kind?, screen?, contains?}`: a ring round every target that matches, without words. With `hints`, their words go on top. |
| `mode` | `add` (default) or `replace`. The same element twice replaces its hint; it never stacks. |
| `numbered` | Number the hints, for a tour. |
| `dim` | The spotlight. |
| `seconds` / `untilClosed` | 2–120 s (default 8 for bubbles, 15 for rings). `untilClosed` waits for the person. |

It answers:

- `set`: an id;
- `shown`: each with `target`, `id`, `as` (`bubble`, `ring` or `list`) and `number`;
- `missing`: the targets that matched none or two, each with its `candidates`;
- `listed`: a count;
- `dropped`: a count, past 100.

### `clear_ui_hints` (view state, new)

`{set?, targets?}`, or every hint. It never touches marks.

### `point_at_ui` (unchanged arguments; adds `title` and `untilClosed`)

- It is `show_ui_hints` with one hint and `mode: add`.
- A second call adds a hint instead of replacing the first. This is what Windows does, and what a
  tour needs.

### Elsewhere

- **`get_current_view`** gains `hints`: the sets up, and the hints in each.
- **The session log** has these calls as calls (plan 23): what was shown, and what went to the list.

---

## V — Bring into view

- **Scrolled out of sight:** before a hint goes up on an element that is clipped by a scroll area,
  the element is scrolled into view with the accessibility action `AXScrollToVisible`. The scroll is
  not animated, as on Windows, so the bubble is placed against a settled frame.
- **Closed and tabbed things are not brought into view** (decisions 1 and 2): `open_ui` and the
  navigation tools do that, on purpose.

## C — Closed things, opened on purpose

- **What is closed:**
  - a section folded shut: an `AXDisclosureTriangle` with `AXExpanded` false;
  - a hidden panel: the app's own panels, each with the control that shows it (the file browser, the
    sidebar, the inspector), named by a hand tag;
  - a menu: an `AXMenuButton`, an `AXPopUpButton`, or a menu bar title.
- **`open_ui {target}`** (view state, new):
  - It opens that one thing: a section by its disclosure, a panel by its own toggle in `AppState`,
    and a menu by the accessibility press.
  - A closed section nested in another opens with its parents, outermost first.
  - It answers what is now inside: the targets, as `list_ui_targets` would list them.
  - On a tab, or on something that is not closed, it refuses, saying why and which tool navigates
    there.
- **`close_ui {target}`** closes it again. A menu closes as the person closes it.
- **Menus are drawn over:**
  - The hint overlay for an open menu sits at the menu's window level, so its bubbles show over it.
  - The app keeps answering while a menu is open: the main actor runs during menu tracking. This is
    checked first in C.
  - If it is not so, menus are listed as closed and `open_ui` refuses them, saying so.

---

## L — Every element has a name (the guardrail)

- **A test hosts every screen.** It hosts the main window in each mode, each Settings section, and
  each sheet `activeSheet` can show, with sample state. It walks each through `AXElementSource` and
  fails, naming them, for:
  - an interactive element with no name;
  - a hand-tagged id that does not resolve;
  - a target outside its window.
- **The fixes it drives are accessibility fixes.** Each is an `.accessibilityLabel` on the field,
  localized. The 24 Search fields come first. VoiceOver users gain the same names.
- **A performance budget:** a snapshot of Search under 150 ms.

## Tests

| Part | Tests |
|---|---|
| `UIElementRules` | Fake trees: machinery dropped; the naming chain in order; clipping by nested scroll areas; ids derived and numbered; hand tags win; SF Symbol identifiers ignored; the approval window excluded; values never read. |
| `UIHintLayout` | Properties over seeded random screens: no two bubbles overlap; no bubble covers a hinted element; all inside; an image canvas avoided when there is room; deterministic; the fewest-spots-first order; the list fallback; at most 12 bubbles; stability under a small move. |
| `UIHintStore` | Add, replace, clear, the same target twice, timers, hover pause, `untilClosed`, the dismissal event once per set. |
| The tools | Matching and `missing` with candidates and the closed things it may be behind; `all` with filters; `point_at_ui` adds; the 100-hint cap; a listing or a hint never opens anything. |
| `open_ui`, `close_ui` | A nested section opens with its parents and nothing else; a tab refused, naming the tool that navigates; a panel by its toggle; a menu's items listed while it is open, and its hints gone when it closes. |
| Hints and marks apart | With marks on an open FITS file: `clear_ui_hints` leaves them; `clear_annotations` leaves the hints; no mark is a UI target. A dependency check: no file in `UIPointer` names a `Mark` type, and none in `Marks` names a `UIHint` type. |
| The guardrail (L) | As above. |
| The spike's test, kept | AX on the app's own windows, sandboxed. |

## Steps

| Step | What | Depends on |
|---|---|---|
| A | `UIElement`, `UIElementSource`, `AXElementSource`, `UIElementRules`; `.pointable` → identifier; `.pointableArea`; the screen name from `AppState`; `list_ui_targets` on it; the registry, anchors and `uiPointerOverlay()` retired | — |
| L | The guardrail across every screen; names for the unnamed; French strings | A |
| Y | `UIHintLayout` in VerbinalKit, with its property tests | — (in parallel with A) |
| O | `UIHintStore`, `UIHintTracker`, `UIHintOverlay`; the click-through check first | A, Y |
| T | `show_ui_hints`, `clear_ui_hints`, `point_at_ui` on the store; `list_events`, `get_current_view`; the tools' words on hints versus marks; AI Guide; the parity doc | O |
| V | Bring into view: the scroll | T |
| C | `open_ui`, `close_ui`: sections, panels, menus; the menu-tracking check first | T |
| W | `describe_app`'s brief; AGENTS.md; the workflows' tours; changelog; handout 28 | all |

Each step is committed on its own, with the gates.

## Decisions

Taken by the person, 2026-09-30:

- "1. open collapsed; tabs active only … ask for other if doubts; 2 inside; 3 controls"
- On hidden panels: "closed things should be opened if there is an intent to show something inside
  them; so if their default state is closed, we need a separate go to open them and show what's
  inside — not just making a full mess"
- On menus: "the same, there should be an intent to open them"

1. **Closed things open only on purpose.**
   - **Closed means:** a section folded shut (`DisclosureGroup`), a panel the person has hidden (the
     file browser, ⌘B; a split view's sidebar; an inspector), a menu (a toolbar menu button, a
     pop-up's choices, the menu bar's menus).
   - **Neither a listing nor a hint ever opens one.** The listing names each closed thing on screen
     as a target with `closed: true` and its kind (`section`, `panel`, `menu`), and nothing behind
     it.
   - **`open_ui` is the separate step,** taken when the assistant means to show something inside. It
     opens that one closed thing — with its closed parents, outermost first, when it is nested — and
     nothing else. Its inside is then on screen: listed and hinted like the rest.
   - **`close_ui` closes it again.** The person can close it too, as they always can.
   - **A menu that `open_ui` opens waits for the person.** They choose from it or press Esc, and a
     hint never chooses for them. Hints on its items go when it closes.
   - **A hint whose target is not on screen** answers `missing` with its candidates, and names the
     closed things on screen it may be behind, so the assistant can decide to open one.
2. **Tabs: the active one only.** A tab not showing — a Search, Results or ADQL tab, a Settings
   section, a page of results — is never switched to, by a listing, a hint or `open_ui`. Its controls
   are not targets; the tab itself is. The assistant goes there with the tools that navigate
   (`navigate_to`, `set_search_tab`, `open_settings`, …), or asks the person.
3. **Scrolled out of view** is not closed: the element is scrolled into view, unanimated, before its
   hint goes up (V).
4. **Inside the window.** Bubbles, badges and the hint list stay within the window's visible content.
   With no room, the list shrinks to a pill ("6 hints") that opens on hover.
5. **`list_ui_targets` lists controls by default** (`kind: "interactive"`). `kind: "all"` adds text,
   images, canvases and areas.

## Risks

- **SwiftUI's accessibility tree is Apple's to change.** The guardrail test catches a change the day
  Xcode moves. Hand tags (`vb:` ids) do not depend on how SwiftUI names things.
- **Menus hold the main run loop in tracking mode.** The main actor is expected to keep running (its
  queue is served in the common modes); this is checked first in C, and menus fall back to closed
  targets if not.
- **Frame tracking cost:** a full snapshot is about 55 ms. Tracking snapshots again only on a change
  signal (move, resize, scroll, screen change), debounced, never on a timer.
- **The accessibility service stops answering while the screen is locked** (seen 2026-09-30: every
  window came back as the application). Nothing can be listed or hinted then — nobody would see a
  hint — and the tools say so (`problem`). The tests that read windows skip, saying why, instead of
  failing.
- **Derived ids change with the language and the layout.** They are marked `stable: false`. Tours and
  handouts use hand-tagged ids.
