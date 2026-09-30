# QA handout — regression pass for plan 21

**Date:** 2026-09-29
**Build:** `release/1.4.0` @ `8efadbe` or later. `describe_app` must say `serverVersion: "1.4.0"`, and its `buildCommit` is the commit to record. A `+` means the build had uncommitted changes.
**Audience:** the MCP QA pass (an assistant connected to Verbinal, with the person watching). ~1½ hours.
**Related:** [Plan 21](./21-qa-plan19-pass-fixes.md) · [Handout 20](./20-qa-regression-plan19.md) · the plan-19 report (`~/Documents/Default Project/qa-report-verbinal-canfar-2026-09-29.md`)

This pass confirms plan 21's fixes, then finishes what the plan-19 pass could not: the cases CADC's
outage blocked, and the two that need one deliberate action each. Record each case as
**PASS / FAIL / BLOCKED**. For a FAIL, attach the tool's JSON or a `capture_view` picture.

The person's standing rules still hold:

- No headless jobs unless the person directs one.
- Nothing is stored on this Mac unless the case says so and the person agrees.
- Destructive changes wait in Pending, for the person to apply.

**Record ids exactly as the tools give them.** The last pass mistyped two record ids, and one of them became a false High defect.

## Setup

1. Build and run Verbinal from `release/1.4.0`, then sign in to CADC.
2. `describe_app`: record `serverVersion` and `buildCommit`.
3. `get_service_health`: record whether `cadc-tap` and `cadc-registry` are up. The registry is now `cadc-west-01.canfar.net`. If `cadc-tap` is down, mark the archive cases BLOCKED and do the rest.
4. Settings ▸ AI Agent: **Allow external AI agents** and **Auto-apply** on; grant the client's prompts.

---

## 1. Plan 21's fixes

| # | Steps | PASS if |
|---|---|---|
| 1.1 | `run_code` `import os; q, p = open('/sys/fs/cgroup/cpu.max').read().split(); print(os.cpu_count(), len(os.sched_getaffinity(0)), int(q)//int(p))`. Read `run_code`'s description and the Remote Compute screen. | The quota gives the session's cores (e.g. 4), while the other two give the node's (192). The description and the screen say to size pools from `/sys/fs/cgroup/cpu.max`. (D2) |
| 1.2 | With `cadc-tap` down (or simulated by the person with a firewall rule, if at all), sign out and in; `list_activity`. | The Research check stops within a few minutes and **fails**: "The archive is not answering — Research records are asked again at the next sign-in". If CADC is up, BLOCKED is fine: the unit tests cover it. (D3) |
| 1.3 | Open the `_x1d` (from VOSpace `sn2023ixf-verbinal-qa/` or the Research record); Export Figure ▸ PNG 2×; `get_fits_spectrum`. | The title is **SN2023IXF** (HST's `TARGNAME`), not the file name. The line under it reads "±1σ band from ERROR — median 0.76% of the flux, narrower than the line". `get_fits_spectrum` has `errorMedianFraction` ≈ 0.0076. (D4) |
| 1.4 | Search with CADC slow or down: a trivial search. | After 10 s, "Waiting for CADC — *n* s" appears beside Cancel. With no answer in two minutes, the search stops and says "CADC's archive is not answering …", with no second two-minute wait. `search_observations` answers the same. (D5) |
| 1.5 | With three interactive sessions running, open the launch sheet; switch between Standard, Advanced and Headless. | "Session limit reached (3/3)" shows on Standard and Advanced, not on Headless. (D6) |
| 1.6 | `get_downloaded_observation` with a record id typed one digit off, e.g. an extra digit in the first group. Then `open_cube` with the NIRSpec cube's **publisher id**, and `get_downloaded_observation` with an 8-character id prefix. | The typo answers "no Research record … — did you mean *the right id*?", never opening anything. The publisher id and the prefix both find the record. (N1) |
| 1.7 | `list_ui_targets` on the Portal; `point_at_ui` `portal.session.<id>.delete` for a throwaway session. | Each session card offers `portal.session.<id>.renew` and `.delete`, labelled with the session's name; the pointer lands on that card's Delete. (N2) |
| 1.8 | `list_downloaded_observations`; open record `2A7511B7-C8DD-491E-8CDF-F4DB229FC7E1` in Research. | It has `duplicateOf: "33AFFFB8-E938-481A-AA7E-9317349A3617"`, and its detail says it is a duplicate kept under a malformed ID that can be deleted. (N3) |
| 1.9 | Propose `delete_session` for a made-up id; the person applies it, then applies it again from Pending; `list_activity`. | The second task reads "Delete session …, again" and has `again: true`. (N4) |

## 2. What the plan-19 pass could not finish

| # | Steps | PASS if |
|---|---|---|
| 2.1 | With CADC up: quit, relaunch, sign in; watch Research and the bar. | "Getting archive details — *n* of *m*" at the top of Research; a task by Verbinal ending "The archive answered for *a* of *m*", with *a* > 0. (handout 20, 4.1) |
| 2.2 | After 2.1, the records `1525350` (`33AFFFB8…`), `1573200` (`880F5F9E…`) and NOAO `tu636792`. | 1525350 and 1573200: ESPaDOnS, Betelgeuse. 1573200's calibration level is that of its file's plane (2 for `1573200i…`). `tu636792`: `mosaic_2`. (4.3, 4.4) |
| 2.3 | Sign out and in again. | No archive task, or a short one: the answers are kept on this Mac. (4.2) |
| 2.4 | From Search, **Save to Research** a result not in Research. | Within a minute, its target, instrument and filter fill in. "Archive details of …" shows on the bar. (4.5) |
| 2.5 | `get_observation_caom2` on a Research record's publisher id, twice. | Both answer, the second at once. (7.3) |
| 2.6 | Only if the person agrees: `download_observation` of a small file. Then `list_downloaded_observations`. | Its path reads `~/Downloads/…`. The record keeps its file and path after its details arrive. (3.2, 7.5) |
| 2.7 | `start_compute` with a size other than the running session's. | The `note` names the session's own size and how it differs from the ask. (1.3's drift clause) |
| 2.8 | The person deletes a throwaway session from its Portal card (confirmed). `list_activity`. | "Delete session …" by **You** (`startedBy: person`). (2.3) |
| 2.9 | Start `discover_image_packages` on a slow image (`astroai/improc:26.09` took minutes) with `start_background_apply`, and quit mid-probe. Relaunch; `get_proposal_state`. | `failed`, "Verbinal quit while this was being applied …". This replaces handout 20's 1.4, whose image finished in seconds. |
| 2.10 | Make an apply fail with a **destructive** tool (`delete_session` of a made-up id; the person applies it). Relaunch; `get_proposal_state`. | Its `failureReason` survives the relaunch. This replaces handout 20's 1.5, whose `renew_session` applies inline and leaves no proposal. |

## Notes

- If `get_proposal_state` forgets a failed proposal that is still in Pending, record its id and the times. A test says it should not.
- L2 (`ra(j20000)` column ids) and N9 (`list_local_folder`) are kept, by decision.

## Leftovers

List everything this pass creates, each deletion through Pending.

From before, still the person's to delete, if they remain:

- throwaway session `qa-person` (`q9p87ajc`)
- workflow copies `…-megacam-2-2` and `…-3-2`
- job `keqh41rx`
- Research `3A03A731`, `850C5ABD`, and the duplicate `2A7511B7`
- saved query `E7A754EE`
- mark `m1` on JADES
- the JCMT workflow copy
- VOSpace `sn2023ixf-verbinal-qa/`
