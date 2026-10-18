# Plan 46 — Move To…: the active record's files to your storage, or back to this Mac

The person (2026-10-18), after asking "can I copy individual observation file into the vo space?" while
looking at a record: "we have a remove file button, delete button, so, on the left of the remove button
"Move To" button that opens a modal to store it in the cloud or locally if it is in the cloud already,
plan this ui wise". Then, deciding:

1. "those badges are redundant as buttons, badges only highlite some state/info, keep them laptop and
   cloud as badges not buttons, and threee other onthe right remove, we have buttons for that; improve
   dialog for file transfers from that small dropdown that badge buttons had."
2. "Copy by default, but it shoul use proper ui / ux to let user see and navigate their choice, wire mcp
   tools that that view and functionality too."
3. "we have cutouts and original record, with or without files, so we need to support every case but
   only to the active item, if user opens a cutout we consider the cutout not the original record etc."

This completes the existing transfers for 1.4.1 — every move already exists in `ResearchFileTransfer`
(copy first; the other copy removed only once the new one is there and storage shows it, plan 44 F-8).
Nothing new is stored or sent.

## The active item

Move To… acts on the record open in Research and on nothing else: a cutout is its own record, with its
own files (the cutout and its companions, such as a weight map); its original observation is another
record. Every case of the active record:

| The record's files | Move To… | The sheet's default |
|---|---|---|
| none anywhere | not shown (Download is) | — |
| on this Mac only | shown | Copy to your storage |
| in your storage only | shown | Copy to this Mac |
| in both places | shown | Keep one copy (see below) |
| several, mixed | shown | each file as its own row says |
| on this Mac by the record, but the file is gone | shown | that file refused: "not on this Mac any more" |

## The Files section: state, not buttons

Each file row: its name, its path on this Mac, its path in storage, its size, and the **badge** — the
laptop and the cloud, lit where it is. The badge is not a control: no menu, no click; its help and
accessibility name say where the file is ("On this Mac and in your storage"), so the tools read it.
The row's three buttons — Open, Show in Finder, Remove — go: the action row has them.

So the action row acts on all of the active record's files:

- **Open in FITS Viewer** opens the main file, as now.
- **Reveal in Finder** shows all of its files on this Mac, selected together.
- **Remove File…** asks which of its files on this Mac to remove (each checked, each saying whether
  storage has a copy), as one confirmation; a record with one file reads as today.

## The action row

```
[Open in FITS Viewer] [Reveal in Finder] [View on CADC] [Copy Details]      [Move To…] [Remove File…] [Delete]
```

**Move To…** (`arrow.left.arrow.right`) is left of Remove File…. Signed out: shown, off, with the help
"Sign in to CANFAR to move files to and from your storage". While one of its files moves: off, "Moving …
— see the activity bar".

## The sheet

```
┌ Move To ─────────────────────────────────────────────────────────────────────┐
│ Cutout of 745234p.fits.fz · D2                                                │
│                                                                               │
│ Where                 ┌ This Mac ─────────┐   ┌ Your storage ──────────────┐  │
│                       │ ~/Downloads       │ → │ Verbinal-Results/research/ │  │
│                       └───────────────────┘   └────────────────────────────┘  │
│                         [ To your storage ▸ ]   [ ◂ To this Mac ]              │
│                                                                               │
│ Files                       now        after                                  │
│  [x] 745234p.cutout-….fits   💻 ·   →   💻 ☁    124 KB                         │
│  [x] 745234p.weight-….fits   💻 ·   →   💻 ☁    124 KB                         │
│                                                                               │
│ (•) Copy — keep it on this Mac too                                            │
│ ( ) Move — remove it from this Mac once it is in your storage                 │
│                                                                               │
│ 248 KB to your storage · 1.2 TB free                                          │
│                                          [Cancel]  [Copy 2 Files to Storage]  │
└───────────────────────────────────────────────────────────────────────────────┘
```

- **Direction, seen.** The two places side by side, This Mac and Your storage, each with where files go
  there, and the direction as a segmented choice between them (To your storage ▸ / ◂ To this Mac). The
  default is where the files are not; a direction nothing can go in is off, saying why ("Already in
  your storage").
- **Each file, now and after.** Its badge as it is, and as it will be — the place that changes is lit.
  Checked by default: those not yet at the destination; one already there is shown off ("Already
  there"); one that cannot go says why under it (a different file of that name is there; the copy in
  storage is gone; not on this Mac any more) and is unchecked.
- **Copy or move.** Two choices, Copy first and chosen (the person's default); Move says which copy goes
  and when. Choosing Move turns its line orange, and the button says Move.
- **In both places already.** The direction becomes **Keep only**: on this Mac, or in your storage. It
  removes the other copy once storage shows its own — what the badge menu's Remove from This Mac… and
  Remove from Storage… did. The button is red (Remove from Storage / Remove from This Mac) and asks once
  more.
- **The summary** says what goes where and how much; for storage, its free space, and stops the button
  when it would not fit.
- **The button** names what happens: Copy to Storage, Move to Storage, Copy to This Mac, Move to This Mac,
  Remove from Storage, Remove from This Mac — with the count when more than one file. Return presses it;
  Escape cancels; Tab goes through direction, files, copy or move, the buttons.
- **On the button** each file moves as its own task on the activity bar (progress, a failure with why,
  Retry — plan 44 E4), and its row shows it moving, then done. The sheet closes itself once every file
  has gone; Cancel becomes Close meanwhile, and the moves carry on. What storage refuses — a different
  file of that name there, the storage copy gone — is only known when tried: the run stops there, the
  reason stays under that file, and the sheet stays open.
- **Keep one copy** is decided as the sheet opens, and stays: a copy just made does not turn the sheet
  into a removal.

## Assistants

The sheet is a presentation (`uiPresented("Move To", .sheet)`): `open_ui` and `close_ui` open and close
it, `list_ui_targets` reads its direction, files, choices and button, `select_ui` picks a segment. And:

- **`show_move_to`** (live, view state): selects the record (by id) if it is not the active one, opens
  the sheet, and sets its direction, files and copy or move, so the person sees the assistant's choice
  and presses the button themselves. Answers what the sheet then shows.
- **`get_move_to_view`** (read): what the sheet shows now — the record, each file now and after, what is
  refused and why, the direction, copy or move, the summary and the button's words; closed when it is.
- **`move_research_files`** (proposal): what the button does, for a record — `files` (default: those not
  at the destination), `to` (`storage` | `mac`), `keepCopy` (default true), or `keepOnly` for a file in
  both places. Its kind is by what it does, as `resolve_sync_conflict`'s: a copy to storage is "Add to
  your CANFAR storage"; a copy to this Mac "Files saved on this Mac"; a move or keep-only removes, and is
  "Remove files on this Mac" or "Remove or replace in your CANFAR storage" by which copy goes. Refused
  when asked for what the sheet would refuse.
- The four one-file tools stay. `docs/agent-ui-parity.md` gets the rows; `AIGuideCatalog` the
  categories; `ChangeCatalog` the kind rule.

## Steps (each one commit, tests failing first)

The sheet comes before the badge loses its menu, so no commit leaves the moves without a way in.
**M1 done:** `MoveToPlan` (Research/MoveTo), `MoveToPlanTests` (12; all fail against a plan that moves by default and leaves the old copy).
**M2 done:** `MoveToModel` (on `ResearchModel.moveTo`), `MoveToSheet`, the button; free space from the quota. `MoveToOnScreenTests` (the button failed first: not there), `ResearchFileTransferTests` Move To (5; a copy flipping the sheet into a removal failed first).
**M3 done:** the Files rows are state — the badge an image named "Where <file> is: …", the rows' Open, Show and Remove gone, the place menu deleted; Reveal in Finder selects every file on this Mac; Remove Files… asks which, a file's only copy unchecked. `ResearchFilesOnScreenTests` failed first (a menu, and the three buttons there); `MoveToOnScreenTests` (reveal, Remove Files).

| Step | What | Tests |
|---|---|---|
| M1 | `MoveToPlan`: from the active record, the direction, the files and copy or move → each file now and after, refusals, the button's words, the summary. Pure. | Every row of the active-item table; a cutout and its original apart; keep-only; a name taken; a storage copy gone; the file gone from this Mac; signed out. |
| M2 | Move To… and the sheet, run through `ResearchFileTransfer` | On screen (AX): the button's place; the sheet's direction, files now and after, copy or move, button words; off when signed out; Escape; a refusal keeps it open. |
| M3 | The Files section as state: the badge not a menu; the row buttons gone; Reveal in Finder and Remove File… over all the record's files | On screen (AX): the badge read with its places, no menu; the row buttons gone; Remove File…'s list. |
| M4 | Free space in the summary | Space short stops the button. |
| M5 | `show_move_to`, `get_move_to_view`, `move_research_files`; kinds; parity rows | Each tool against the sheet; the kind by effect; a refusal when asked. |
| M6 | Words in English and French; manual 03 (en, fr); handout cases | Words checked against the screen. |
