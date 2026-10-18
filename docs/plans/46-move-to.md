# Plan 46 — Move To…: a Research file to your storage, or back to this Mac

The person (2026-10-18), after asking "can I copy individual observation file into the vo space?" while
looking at a record: "we have a remove file button, delete button, so, on the left of the remove button
"Move To" button that opens a modal to store it in the cloud or locally if it is in the cloud already,
plan this ui wise".

The moves exist already — the place badge in the Files section is a menu (Send a Copy to Storage, Move
to Storage…, Get a Copy from Storage, Move to This Mac…, Remove from …) — but nothing says the badge is a
menu, and the record's own buttons do not offer them. This completes that feature for 1.4.1; it adds no
new storage capability, and uses `ResearchFileTransfer` as it is (copy first, the other copy removed only
once the copy is there and storage shows it — plan 44 F-8).

## Where it goes

The record's action row, right group, left of **Remove File…**:

```
[Open in FITS Viewer] [Reveal in Finder] [View on CADC] [Copy Details]      [Move To…] [Remove File…] [Delete]
```

- Shown when the record has a file anywhere: on this Mac, in storage, or both.
- Signed out: shown, off, with the help "Sign in to CANFAR to move files to and from your storage" (the
  badge's words).
- While one of its files is moving: off, with the help "Moving … — see the activity bar".

## The sheet: "Move To"

```
┌ Move "D2 — 745234" ────────────────────────────────────────────┐
│ Files                                                           │
│  [x] 745234p.cutout-b635f540.fits   124 KB   💻 ☁   On this Mac │
│  [ ] 745234p.weight.fits            124 KB   💻 ☁   Both        │
│                                                                 │
│ To   ( ) Your storage   Verbinal-Results/research/              │
│      ( ) This Mac       ~/Downloads                             │
│                                                                 │
│ [x] Keep the copy where it is now                               │
│                                                                 │
│ 124 KB to your storage · 1.2 TB free                            │
│                                                   [Cancel] [Copy]│
└─────────────────────────────────────────────────────────────────┘
```

- **Files.** Each of the record's files — the main one, then the others (companions, other files) —
  with its size and places. Checked by default: those not yet at the chosen destination. A file
  already there is shown, unchecked and off ("Already in your storage").
- **To.** Your storage, or this Mac. The default is the place the files are not: a file only on this
  Mac → storage; only in storage → this Mac. Both places: storage, and nothing is checked until the
  person asks to keep a single copy (below).
- **Keep the copy where it is now.** On: a copy (both places after). Off: a move (the copy where it was
  is removed once the new one is there and storage shows it). The default is on: nothing is removed
  unless the person turns it off; the button then says Move, and the sheet says which copy goes.
- **Summary line.** What goes where and how much; for storage, its free space (`get_storage_quota`'s
  source), and a warning when it would not fit.
- **The button** names what happens: **Copy to Storage**, **Move to Storage**, **Copy to This Mac**,
  **Move to This Mac**. Return presses it; Escape cancels.
- **On click** the sheet closes at once. Each file moves as its own task on the activity bar (as today:
  progress, failure with why, Retry — plan 44 E4); the badge shows it busy. A file that cannot go is
  refused before anything moves, saying why (another file of that name there, not in storage, the
  storage copy gone — F-8), and the sheet stays open with the reason under the file.
- **Remove instead.** Removing a copy without moving is Remove File… and the badge menu, as now.

## The badge menu

Kept as it is: the badge says where each file is, and its menu stays a quick way for one file. Open
question 1 below asks whether it should become a plain indicator instead.

## Assistants

No new tool: the four transfer tools are the sheet's moves, file by file (`send_research_file_to_storage`,
`get_research_file_from_storage`, then `remove_research_file_from_mac` / `_from_storage` for a move).
For parity of sight:

- the sheet is a presentation (`uiPresented("Move To", .sheet)`): `open_ui` opens it, `list_ui_targets`
  reads its files, destination and button, `select_ui` picks the destination segment; nothing in it is
  pressed by an assistant;
- `docs/agent-ui-parity.md` gets a row.

## Steps (each one commit, tests failing first)

| Step | What | Tests |
|---|---|---|
| M1 | `MoveToPlan`: from a record, its files, the destination and keep-a-copy → what each file does, the button's words, the summary, what is refused and why. Pure. | Every case: only here, only there, both; several files; one already there; keep on and off; a name taken; signed out. |
| M2 | The button and the sheet; runs the plan through `ResearchFileTransfer` | On screen (AX): the button left of Remove File…; the sheet's files, destination, toggle and button words; off when signed out; Escape. |
| M3 | Free space in the summary; refusal shown in the sheet | Space short; a refusal keeps the sheet open with its reason. |
| M4 | Words: English and French; manual 03 (en, fr); the parity table; handout cases | Words checked against the screen. |

## Open questions for the person

1. **The badge menu:** keep it as a second way (as planned), or make the badge only say where the file
   is, so Move To… is the one place moves start?
2. **Copy or move by default:** keep a copy (planned: nothing removed unless asked), or move?
3. **Several files:** one sheet for all the record's files (planned), or one file at a time?
