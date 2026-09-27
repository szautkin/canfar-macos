# QA handout — Windows catch-up Phase A (correctness)

**Date:** 2026-09-26
**Build:** `release/1.4.0` @ `1d3be2f` or later
**Audience:** live tester (UI + MCP). ~60 minutes.
**Related:** [Windows catch-up plan](./10-windows-catchup.md) · [MCP setup](../MCP-Setup.md)

Phase A fixes only. Do not file missing marks, cutouts, `list_apps`,
`get_fits_image`, the ADQL checker or the Remote Compute screen — those
are later phases. Record each case as **PASS / FAIL / BLOCKED**, with the
tool JSON or a screenshot on FAIL.

## Setup

1. Build and run Verbinal from `release/1.4.0`. Settings ▸ AI Agent:
   **Allow external AI agents** on.
2. Point the MCP client at this build (`…/Verbinal.app/Contents/MacOS/Verbinal mcp`).
3. Sign in to CADC. Download one HST calibrated frame (`*_flt.fits` or
   `*_flc.fits`), one ordinary image, and — if you can — one file over
   1 GB (a MegaPipe tile).

---

## 1. Positions (A1–A3)

| # | Steps | PASS if |
|---|---|---|
| 1.1 | FITS Viewer ▸ Go To: type `10,68` and `41,27` (decimal comma), then `00:42:44.3` / `+41:16:09`, then `abc`. | The first two move the view; `abc` shows "Enter RA and Dec in degrees or sexagesimal". |
| 1.2 | Put the crosshair on a star, then Go To a position well off the image. | The toast names the pixel it would fall on; `fits_goto_coordinate` with the same position says e.g. "… px left of the image" and gives `pixelX`/`pixelY`. |
| 1.3 | On any image, look for a position near a whole minute (the readout, a bookmark, the figure legend). | Never `…m60.00s` or `…'60.0"`. |
| 1.4 | HST frame: crosshair on a star near a **corner**; compare RA/Dec with ds9 or astropy (`all_pix2world`, origin 0) on the same file and HDU. | Agrees to about 0.01″. Before the fix it was off by up to ~0.3″ (several pixels). |
| 1.5 | HST frame: `get_fits_wcs` with only the observation id. | `hduChosenBy` is `firstWithWCS` (file closed) or `onScreen` (file open); `hasWCS` is true. |
| 1.6 | Colormap Viridis on any image; export a figure. | Dark purple → teal → yellow, as in matplotlib; not teal → orange. |

## 2. The assistant while Verbinal is closed (A4)

1. Quit Verbinal. Start the assistant (or restart its MCP connection).
   **PASS if** the connection succeeds (no "failed to connect") and the
   tool list is the one Verbinal gave last time.
2. Call any tool (e.g. `describe_app`). **PASS if** it returns a readable
   error saying Verbinal is not running and to turn on Allow external AI
   agents — not a protocol error.
3. Start Verbinal. Within a few seconds, without reconnecting, call
   `get_current_view`. **PASS if** it works. (Clients that honour
   `tools/list_changed` refresh their list.)
4. Ask for a slow call (e.g. `search_observations` on a busy target) and
   quit Verbinal while it runs. **PASS if** the call gets an error
   ("Verbinal closed before answering …"), not a hang.

## 3. Search (A5)

| # | Steps | PASS if |
|---|---|---|
| 3.1 | Run a search that takes a while (broad target, no filters); press **Cancel** (or Esc). | The spinner stops at once; the previous results stay; no error banner; Recent Searches has no new entry. |
| 3.2 | Same in the ADQL editor. | Same. |
| 3.3 | Agent: `run_search`, then `cancel_search` from a second call while it runs. | `cancel_search` → `cancelled: true`; the `run_search` reply says `cancelled: true`. With nothing running, `cancel_search` → `cancelled: false`. |

## 4. Sessions and batch jobs (A6)

1. Launch a session from the Portal. **PASS if** the strip refreshes
   within ~5–8 s of it coming up and a **Session Ready** notification
   appears (French UI: "Session prête").
2. Launch a headless job that fails at once (bad command).
   **PASS if** a **Batch Job Failed** notification appears within ~20 s,
   even though it never showed as Running.
3. Relaunch Verbinal with a failed job already in the list.
   **PASS if** nothing is announced for it.
4. Sign out. **PASS if** Console shows no further session polling from
   Verbinal.

## 5. Opening files through the assistant (A7)

| # | Steps | PASS if |
|---|---|---|
| 5.1 | `open_fits_file` on the >1 GB file. | Within ~40 s the reply is `stillLoading: true` with a note; the image arrives later on its own; one tab only. |
| 5.2 | `open_fits_file` on a file that is already open (a second time). | Its tab is focused; the tab count does not grow. |
| 5.3 | Open the same file from Research twice by hand. | Same — one tab. |
| 5.4 | `list_open_tabs` with a cube open. | `cubeTabs[].path` is the full path. |

## 6. Tool descriptions (A8)

1. `tools/list` in the client. **PASS if** `delete_vospace_node` (or any
   delete) ends with "Destructive: it always waits in Pending …", and
   `save_query` ends with the Auto-apply sentence.
2. In AI Guide, write your own description for `save_query`.
   **PASS if** `tools/list` shows your text followed by the Auto-apply
   sentence.
3. With Auto-apply **on**, call `delete_saved_query`. **PASS if** it waits
   in Pending (it is destructive) and the reply says so.

---

## Results log

| # | Case | Result | Notes |
|---|---|---|---|
| 1.1–1.6 | Positions | | |
| 2 | Closed / starting / quitting app | | |
| 3.1–3.3 | Search cancel | | |
| 4 | Polling and notifications | | |
| 5.1–5.4 | Opening files | | |
| 6 | Tool descriptions | | |

**Tester:** · **macOS:** · **MCP client:** · **Blockers:**
