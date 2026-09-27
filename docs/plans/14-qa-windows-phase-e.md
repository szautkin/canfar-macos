# QA handout — Windows catch-up Phase E (Portal, images, compute, polish)

**Date:** 2026-09-27
**Build:** `release/1.4.0` @ `f5e8e97` or later
**Audience:** live tester (UI + MCP). ~2 hours.
**Related:** [Windows catch-up plan](./10-windows-catchup.md) · [Phase D handout](./13-qa-windows-phase-d.md) · [AGENTS.md](../../AGENTS.md)

The Portal and its images card, images the catalogue does not list,
Remote Compute, the activity bar and job history, large FITS images,
and the finishing touches. Record each case as **PASS / FAIL / BLOCKED**,
with the tool JSON or a screenshot on FAIL.

## Setup

1. Build and run Verbinal from `release/1.4.0`; sign in to CADC.
2. Settings ▸ AI Agent: **Allow external AI agents** on; register the MCP
   client as `AGENTS.md` says (section 4) — this is also case 7.3.
3. Settings ▸ Image Discovery: your Harbor username and CLI secret.
4. For section 4: a compute image in Settings ▸ AI Compute (the
   `verbinal-execution` image), or skip section 4 as BLOCKED.
5. For 6.1: a MegaPipe tile (≈ 20315 × 20475) on disk, and a small image.

---

## 1. The Portal and its images card (E1, E2)

| # | Steps | PASS if |
|---|---|---|
| 1.1 | Open the Portal in a wide window, then narrow it below 1000 pt. | Wide: platform load, storage, batch jobs across the top; sessions full width; images beside recent launches. Narrow: one column, same order. |
| 1.2 | Active Sessions ▸ **Launch Session**. | The launch form opens in a sheet; launching closes it. |
| 1.3 | Images card: click a type chip, then a project chip (skaha). | Rows narrow to that type and project; counts on the chips; "All projects" restores. |
| 1.4 | Assistant: `show_launch_form` with `tab: advanced` and `image: images.canfar.net/skaha/astroml:<tag>`. | The sheet opens on Advanced with that image **once** (not `images.canfar.net/images.canfar.net/…`); launching it works. |
| 1.5 | Advanced tab: paste ` https://images.canfar.net/skaha/<name>:<tag>` into the image field; launch. | Launches the image; no scheme in the session's image. |
| 1.6 | Assistant: `list_session_images` with `project: skaha`. | Only skaha images, each saying its project. |

## 2. Images the catalogue does not list (E3)

| # | Steps | PASS if |
|---|---|---|
| 2.1 | Images card ▸ **Find in Registry…** ▸ search `astro`. | Results with their session types (or "No session type — launch it from the Advanced tab"); a wrong secret says "Use your Harbor CLI secret, not your CADC password". |
| 2.2 | **Add** one; close the sheet. | The card's **Added** tab lists it; its type tab too; the launch form offers it under its type. |
| 2.3 | Find in Registry ▸ Your images ▸ **Remove**. | Gone from the Added tab and the launch form at once. |
| 2.4 | Assistant: `search_image_registry` `astro`; `add_registry_image` one; `list_my_images`; `remove_registry_image` it. | Added ones carry `addedAt`; add applies (auto-apply on); remove **waits in Pending** (destructive); an image with no tag is refused before a proposal. |
| 2.5 | Assistant: `search_packages` `spec`; `describe_image` a probed image with `filter: astropy`. | Names like specutils, shortest first, per ecosystem; the image's OS, Python, sections with versions; an unprobed image is refused with "run discover_image_packages". |

## 3. Batch jobs and the activity bar (E5)

| # | Steps | PASS if |
|---|---|---|
| 3.1 | Watch the bar at the bottom of the window while inspecting an image (Find by package ▸ Inspect). | "Inspect … — Waiting for job …" with its stage; then Idle; the list (click) shows it with its time. |
| 3.2 | Upload a file to Storage and delete it; download an observation. | Each is on the bar; a failure shows "1 failed" in red and its reason in the list; **Clear Finished** empties the finished. |
| 3.3 | Launch a batch job that fails (a bad command); wait until CANFAR removes it. | Batch Jobs ▸ **History** keeps it with Failed and the status; probes from 3.1 appear as "Image inspection — …". |
| 3.4 | Assistant: `list_activity`; `list_job_history` `failedOnly: true`. | The same as on screen. |

## 4. Remote Compute (E4)

| # | Steps | PASS if |
|---|---|---|
| 4.1 | Signed out: the home screen. | The Remote Compute tile is locked; clicking it asks you to sign in, then opens it. |
| 4.2 | Without a compute image: open Remote Compute. | The setup steps, Open Settings, the repository link; no Run box. |
| 4.3 | With an image: **Start Session**. | "Starting"; within a couple of minutes "Running · N cores · M GB · up … min". |
| 4.4 | Run Code tab: `print(6*7)`, Run. | The run appears as "You · python · running", then ok with Output 42; **Run Again** makes a second. |
| 4.5 | Assistant: `run_code` `print(1)`; `list_compute_runs`; `show_compute_run`; `set_compute_snippet` `echo hi` bash. | The run is "Assistant · …"; the screen selects it; the box fills with `echo hi` and nothing runs until you press Run. |
| 4.6 | **Open Folder in Storage**; assistant `show_storage_folder` `.verbinal/exec`, then `/someone-else/x`. | Storage opens at `.verbinal/exec`; someone else's path is refused. |
| 4.7 | **Stop Session** ▸ confirm; assistant `get_compute_state`. | "Stopped"; the tool says `stopped`, with the size asked for. |
| 4.8 | Settings ▸ AI Compute: paste `https://images.canfar.net/...` as the image. | Kept without the scheme. |

## 5. FITS: recents and loading (E6b)

| # | Steps | PASS if |
|---|---|---|
| 5.1 | FITS viewer with nothing open. | **Open FITS File…** and "Recently opened" with the last files; one moved away is forgotten with "no longer available". |
| 5.2 | Open a large or fpack file. | The loading screen names its stage: the header, "Reading/Uncompressing W × H pixels", "Drawing". |
| 5.3 | Cube viewer with nothing open. | Its recent cubes are still there (same list as before the update). |
| 5.4 | Assistant: `list_recent_fits`. | The same files as the empty screen. |

## 6. Large images (E6a, C8)

| # | Steps | PASS if |
|---|---|---|
| 6.1 | Open the MegaPipe tile. | It opens (with a few GB free); pan and zoom are smooth; stars are there when zoomed out. |
| 6.2 | Crosshair on a star, zoomed in; compare RA/Dec and value with ds9. | Same position and the full-resolution value (not an average). |
| 6.3 | Marks, Go To, Export Figure on the tile. | Marks sit on their stars; Go To lands; the figure is right. |
| 6.4 | With little memory free (many apps open), open it again. | Either it opens, or it says the size, what is needed and what is free, and suggests a cutout. |

## 7. Finishing touches (E7)

| # | Steps | PASS if |
|---|---|---|
| 7.1 | Ask the assistant for any tool; wait three seconds. | One sound when it starts, one when it stops — not one per call; Settings ▸ AI Agent's switch silences them. |
| 7.2 | Verbinal ▸ About Verbinal ▸ **Copy Details**; paste. | App version and build, macOS build, Mac, architecture, GPU, memory, install — one per line. |
| 7.3 | Follow `AGENTS.md` for your client from scratch. | `describe_app` answers; every command in it is right for this Mac. |
| 7.4 | VoiceOver on: results pager, unit menu, FITS new tab and bookmark, batch-job info and delete. | Each is read by what it does, not by its icon's name. |
| 7.5 | The home screen. | Portal, Remote Compute, Storage, Search, Research, FITS Viewer, Cube Viewer, the addon tile, Workflows, (AI Guide), AI Assistant. |

---

## Results log

| # | Case | Result | Notes |
|---|---|---|---|
| 1.1–1.6 | Portal and images card | | |
| 2.1–2.5 | Registry and my images | | |
| 3.1–3.4 | Activity bar and job history | | |
| 4.1–4.8 | Remote Compute | | |
| 5.1–5.4 | FITS recents and loading | | |
| 6.1–6.4 | Large images | | |
| 7.1–7.5 | Finishing touches | | |

**Tester:** · **macOS:** · **MCP client:** · **Blockers:**
