# Plan 21 — Fixes from the plan-19 regression pass (Sept 29, 2026)

**Date:** 2026-09-29
**Branch:** `release/1.4.0` (continues [plan 19](./19-qa-report-fixes.md))
**Source:** *verbinal-canfar MCP — QA Regression Pass for Plan 19* (`~/Documents/Default Project/qa-report-verbinal-canfar-2026-09-29.md`), against [handout 20](./20-qa-regression-plan19.md).

The pass scored 12 PASS, 2 FAIL, 4 PARTIAL and 6 BLOCKED. Every BLOCKED case was CADC's archive
being down (`ws.cadc-ccda…` refused TCP 443 from 00:33 UTC), apart from 2.3, which waits on
the person's click. This plan checks each of the report's findings against the code and the
files on this Mac before fixing anything. The same rules as before apply: a failing test on
the reported case first, one owner per rule, and one green commit per step.

## Status

| Step | State | Commit |
|---|---|---|
| V version | done — 1.4.0, build 17; `buildCommit` | V |
| D2 pool sizing | done — the cgroup quota | D2 |
| D3 archive outage | done — stops after 4 unanswered, fails | D3 |
| D4 spectrum figure | done — TARGNAME; the error's size said | D4 |
| D5 TAP timeout | done — no retry after a timeout; the wait shown | D5 |
| D6 limit banner | done — interactive tabs only | D6 |
| R registry | done — `cadc-west-01.canfar.net/reg` by default (the person's request) | R |
| N small items | done — N1 a typed id names its likely record; any identifier finds it; N2 each card's Renew and Delete pointable; N3 a slash-form duplicate marked; N4 a repeat of a failed task says "again"; N5 pinned by a test (not a defect) | `0e9653d`, `3362a69`, `4424489`, `1612e5e`, N5 |
| Q handout 22 | done — [handout 22](./22-qa-regression-plan21.md) | Q |

## What the report got wrong

| Report item | Checked | Finding |
|---|---|---|
| **0.1** "the build is 1.3.4, not `release/1.4.0`" | `project.yml`: `MARKETING_VERSION: "1.3.4"`, `CURRENT_PROJECT_VERSION: "17"`, never raised on this branch | **The build is release/1.4.0.** Every plan-19 behaviour the pass confirmed exists only on this branch: "no such session", "Verbinal quit while this was being applied", `drawnBy`, "Answered from the cache". The version string was never bumped, so QA could not tell which build it had. That is step V, not a wrong build. |
| **D1 (High)** "record `475879F9E-122A-…` listed with `fileExists: true` is unopenable" | Research store on this Mac: the record is `475879F9-122A-4CD3-9E37-A336ABFEBD0A` | **Not a defect: a mistyped id.** QA passed a first group of 9 hex digits, one too many, and no record has that id. QA's other quoted id, `2A7511B7-…-F4DB29FC7E1`, also dropped a digit (the store has `…F4DB229FC7E1`). `open_cube` by publisher id is not a form the tool takes. Kept as N1: a miss names the id it most likely means. |
| **D6 (Low)** "`launch_headless_job` bypasses the 3/3 session limit the UI enforces" | `HeadlessLaunchModel.canLaunch` does not look at the limit; `LaunchFormView` shows the interactive-session banner above every tab | **The MCP is right; the banner misleads.** The limit of 3 is for interactive sessions (`SessionLaunchModel.maxConcurrentSessions`, counted from the session list, which excludes headless). CANFAR accepts batch jobs beyond it, as the pass's two launches show. Launch Job was disabled because the form's fields were empty. Fix: the banner shows only on the interactive tabs. |

## Defects confirmed

| Step | Finding | Cause (found) | Fix |
|---|---|---|---|
| **V** | 0.1 | See above. | `MARKETING_VERSION` 1.4.0 on this branch (decision 1). `describe_app` also reports the build's git commit (`buildCommit`, written into Info.plist at build time), so a handout's "`@ 62bdbf6` or later" can be checked. |
| **D2** | 6.2 (High) | K2's advice was wrong. CANFAR limits a session with a CFS quota (`/sys/fs/cgroup/cpu.max` = `400000 100000`), not a cpuset, so `sched_getaffinity` covers all 192 node CPUs, as `cpu_count()` does. | `run_code`'s description and the Remote Compute screen give the working signal: the cgroup quota (`quota ÷ period` from `/sys/fs/cgroup/cpu.max`), with a two-line snippet. `get_compute_state` already reports `sessionCores`. |
| **D3** | 4.1 (Medium) | With the archive down, each record waited out `caom2ops/meta`'s 60 s timeout, two at a time: 36 records took 18 minutes, and the task still ended **succeeded**: "answered for 0 of 36". | The check stops once the archive has answered none of its first four requests: "The archive is not answering — Research records are asked again at the next sign-in". It **fails** when the archive answered for none. A partial answer succeeds and says how many. |
| **D4** | 3.1 (Medium) | *Checked on the pass's own file:* an HST file has no `OBJECT`; its target is `TARGNAME` (SN2023IXF), so the caption fell back to the file name. The error band is drawn, but this spectrum's median error is 0.76% of the flux, about 0.5 pt at the figure's scale: thinner than the 1 pt line. Rendered here to confirm. | `FITSFigureCaption` reads `OBJECT`, else `TARGNAME`, for images too. The spectrum names its error: "±1σ band from ERROR — median 0.8% of the flux", and says when the band is narrower than the line, rather than leaving the reader to look for it. The band's opacity rises so a thin band shows. |
| **D5** | 7.3, Search (Medium) | A TAP search on a dead host: `timedOut` is "transient", so the query is tried three times at 120 s each, about 6 minutes behind a spinner. | The TAP path does not retry after a timeout (the host has had two minutes), and has an overall budget. The Search screen says "Waiting for CADC — *n* s" with Cancel, and after a timeout "CADC's archive is not answering" (as `get_service_health` saw). `search_observations` answers the same. |

## Small items the report raised

| Step | Item | Fix |
|---|---|---|
| **N1** | D1's mistyped id | A lookup that misses names the id it most likely means: same length, or one digit added or dropped. It never acts on the guess. |
| **N2** | The Portal session card's Delete and Renew are not pointable | Each card's Delete and Renew are pointable targets, by session id. |
| **N3** | `2A7511B7-…`: a second `1525350` record under the slash form, with the 0-byte `pkg-….txt` file | R3 leaves it, rightly, as the corrected id is taken by `33AFFFB8-…`. It is marked as a duplicate of that record, in Research and in `list_downloaded_observations` (`duplicateOf`), for the person to delete. |
| **N4** | 1.1: the same failed delete appears twice on the bar, 5 s apart | A failed proposal stays in Pending for retry, and the person applied it again. Any task that repeats one that failed says "again", on the bar and in `list_activity` (`again`). *Not done:* withholding the retry of an apply that can never succeed (no such session). That would need a failure marked permanent, one that keeps its reason after leaving Pending, and a retry fails again saying the same. |
| **N5** | "`get_proposal_state` forgets failed proposals after ~5 min though the item stays in Pending" | *Not reproduced from the code:* a pending proposal's state is read from the live queue, not a tombstone, until it expires (3 h). What the pass likely saw is an auto-applied write that failed inline (e.g. `renew_session`), which is withdrawn, with the failure in the tool's answer. A test now pins it: a failed proposal still pending reads `failed`, with its reason, 30 minutes on. Handout 22 asks for the id and the times if it recurs. |

## Handout corrections (for handout 22)

- 1.4: name a slow image. `astroai/improc` took 240 s, while a warm cluster finishes most probes in 3–15 s.
- 1.5: make the apply fail with a destructive tool (`delete_session` of a made-up id), which waits in Pending. `renew_session` applies inline.
- Re-run with CADC up: 3.2, 4.2–4.5, 7.3, 7.5. Also 1.3's drift clause (stop, then start at another size) and 2.3 (the person deletes from the Portal).

## For the person

- `qa-person` (`q9p87ajc`) is still running: delete it from the Portal, which also completes 2.3.
- The pass's leftovers are in §5 of the report; each deletion goes through Pending.

## Decisions

1. **V (2026-09-29):** 1.4.0, the same build number (17) — nothing has been published as 1.4.0.
