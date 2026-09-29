# Plan 17 — Fixes from the plan-15 regression pass (Sept 28, 2026)

**Date:** 2026-09-28
**Branch:** `release/1.4.0` (continues [plan 15](./15-qa-mcp-pass-fixes.md))
**Source:** the regression runs appended to *Verbinal macOS — QA Findings
(MCP pass, Sept 2026)* — run 1 (11:45–12:25 UTC), run 2 and its part 2
(to 12:45 UTC), against this branch at about `c1ba0e3`.

Of plan 15's findings, 38 now pass. What remains: what still fails or is
partly fixed (phase G), the audit gaps the runs uncovered (A), what the
person asked for on screen (U), and probes and privacy (P). Run 1's two
hangs (R1, R2) were unanswered approval prompts in the client, not the
app, and are withdrawn. The same rules as plan 15: a failing test on the
reported case first, one owner per rule, one green commit per step
(app tests, VerbinalKit tests, iOS build), a CHANGELOG entry, and the
parity doc for tool changes.

## Status

| Phase | State | Commits |
|---|---|---|
| G what still fails | in progress — G1 BYTEPIX; G2 files checked through their bookmark; G3 records kept before, corrected once; G4 the image's header, `keywords`; G5 dotfiles are text; G6 a probe's error line; G7 `.vnc` | `871bfb9`, `1d32617`, `8400303`, `23a9b3b`, `09069c7`, `2d91b62`, G7 |
| A audit | planned — A1–A5 | — |
| U the screen | in progress — U1 the robot on every view | `9b56ce0` |
| P probes and privacy | planned — P1–P3 | — |

## The open question: who deleted `notebook1`?

The activity bar's "Delete session xb0b7mu3" (12:23:52 UTC, 05:23 local)
has one source in the code: the Portal session card's **Delete**, after
its confirmation dialog (`SessionListView` → `SessionListModel.deleteSession`).
Nothing in the app deletes a session by itself, and an assistant's
`delete_session` never writes that line — it calls the service directly
and waits in Pending. So it was a confirmed click in the Portal. What the
runs rightly found is that the trail cannot say whose (A1).

## G — What still fails

| Step | Finding | Cause | Fix |
|---|---|---|---|
| **G1** | H1 | *Confirmed:* CFHT's tables name only BLOCKSIZE; FITS 4.0 and cfitsio default BYTEPIX to 4 (32-bit Rice for 16-bit images); the decoder took 2. | Default 4. — `871bfb9` |
| **G2** | H2 | *Confirmed:* the check reads the path without the record's security-scoped bookmark, and treats a file it cannot open as fine — so the all-zero tar in `~/Documents/test_qa` passed. `downloaded: true` for a file that holds nothing. | One way to open a record's file, bookmark first (`DownloadedObservation`, used by the check, the viewers and Research); a file that cannot be read is a problem (`unreadable`); `list_downloaded_observations` says `downloaded: false` for a file with a problem. |
| **G3** | H5, M2 | Plan 15 corrected new records only; the MegaPipe record and the blank observation ids were saved before. | Research records are checked against the archive once, in the background on the activity bar (`ResearchRecordDetails` on each, publisher id first); the details of the plane replace what was given. |
| **G4** | M17 | `EXTNAME = 'COMPRESSED_IMAGE'` is fpack's name for the table, dropped by cfitsio; blank cards pad the header; `get_fits_header` has no filter. | `TileCompression.fate` of a card, not a keyword: that EXTNAME and blank cards are dropped. `get_fits_header` takes `keywords` (names or prefixes). |
| **G5** | L5 | `.bashrc` has no extension, so the server's `octet-stream` stood. | `VOSpaceContentType`: a dotfile with no extension is text (`.DS_Store` excepted). |
| **G6** | L17 | The log's last line was a status message; a probe that failed without a log said nothing. | The failure reason is the last line that reads as an error (Error, Traceback, Killed, OOM, …), else the last Warning event, else the status. |
| **G7** | M14 | *Not reproduced:* a CADC-shaped listing with a public `.token` gives `exposedSecret: true` and the warning. `.vnc` was not in the rule. | `.vnc` added; the regression handout asks for the exact `list_vospace_path` answer if it recurs. |
| **G8** | M18 | A tab with no sky WCS makes the sync imprecise but is not named. | `set_tab_sync` and the tab bar name the tabs without a sky WCS, as they name fields apart. |
| **G9** | M19, L13 | Search results have no pointable controls; `set_adql_editor` says `executed: true` for a query it refused. | Pointable targets on the results toolbar and form fields; a refused query is `executed: false` with the reason (`SearchOutcome.refused`). |
| — | H8 (`qa-test-headless`) | It ended and was forgotten by the platform before this build ran; there is nothing left to record. New jobs are kept (run 2). | None. |
| — | L2 | Kept by decision: the column ids are the keys Verbinal for Windows uses. | None. |

## A — Audit

| Step | Finding | Fix |
|---|---|---|
| **A1** | notebook1 | Every task on the activity bar says who started it — the person, an assistant, or the app itself — and `list_activity` reports it. The assistant's `delete_session`, `renew_session` and bulk deletes go through the same owner as the Portal (`SessionListModel`), so they appear on the bar too. |
| **A2** | N2 | A headless job an assistant launched is recorded `origin: agent` (the launch notes its job ids for the history). |
| **A3** | N3, N8 | `launch_headless_job` returns the job ids; `export_fits_figure` and `export_cube_figure` return the file they wrote. |
| **A4** | N7 | A failed apply keeps its reason on the proposal — the strip and `get_proposal_state` show it; withdrawing a proposal gives its budget back. |
| **A5** | N10 | Investigate: a session Pending after its container started is Skaha's status; if its events show the container running, say "Starting". `get_session` not loading through the client's tool search is on the client. |

## U — The screen (asked for by the person)

| Step | Finding | Fix |
|---|---|---|
| **U1** | N11 | The pending-changes robot is always in the window's toolbar beside Settings and Info — on every view, Landing and Portal included — with its count; it opens Pending, where destructive changes wait. Pointable (`agent.pending`). |
| **U2** | N12 | Batch Jobs always shows its summary — "0 running · 0 pending · 1 done · 1 failed" — including zeros. |
| **U3** | N6 | No empty cube tab: opening a cube replaces an empty tab, and `list_open_tabs` never lists one. |
| **U4** | N1 | A FITS file whose extension is a table (a spectrum's `_x1d`) opens as a spectrum: its wavelength and flux columns plotted (with errors when the table has them), not a blank 38946×1 image; a table with no spectrum in it says so and lists its columns. The plot is readable by assistants too. |
| **U5** | N5 | A suggested cutout names the same cutter as the file's options. |

## P — Probes and privacy

| Step | Finding | Fix |
|---|---|---|
| **P1** | N4 | A probe answered from the cache says `cached: true` and when it was taken. Investigate the one-package manifest of `astroai/improc:latest` — likely the probe's `python3` is not the image's environment (conda) — and probe each Python it finds. |
| **P2** | N9 | No change: `list_local_folder` lists every file in the folders the person has given Verbinal, as the person's own permissions allow (decision 2). |
| **P3** | — | Regression handout 18 for these steps, as handout 16 was for plan 15. |

## Decisions (2026-09-28)

1. **U4:** build the spectrum plot now.
2. **P2:** `list_local_folder` lists all files, as the person's permissions allow.
3. **U1:** the robot that opens Pending — where destructive changes wait — is always visible, Landing and Portal included.
