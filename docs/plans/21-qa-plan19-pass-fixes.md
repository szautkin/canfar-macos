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
| V version | planned (decision 1) | — |
| D2 pool sizing | planned | — |
| D3 archive outage | planned | — |
| D4 spectrum figure | planned | — |
| D5 TAP timeout | planned | — |
| D6 limit banner | planned | — |
| N small items | planned | — |
| Q handout 22 | planned | — |

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
| **D2** | 6.2 (High) | K2's advice was wrong. CANFAR limits a session with a CFS quota (`/sys/fs/cgroup/cpu.max` = `400000 100000`), not a cpuset, so `sched_getaffinity` covers all 192 node CPUs, as `cpu_count()` does. | `run_code`'s description and the Remote Compute screen give the working signal: the cgroup quota (`quota ÷ period` from `/sys/fs/cgroup/cpu.max`), with a two-line snippet. `get_compute_state` reports the session's cores. |
| **D3** | 4.1 (Medium) | With the archive down, each record waited out `caom2ops/meta`'s 60 s timeout, two at a time: 36 records took 18 minutes, and the task still ended **succeeded**: "answered for 0 of 36". | The check stops once the archive has answered none of its first four requests: "The archive is not answering — Research records are asked again at the next sign-in". It **fails** when the archive answered for none. A partial answer succeeds and says how many. |
| **D4** | 3.1 (Medium) | *Checked on the pass's own file:* an HST file has no `OBJECT`; its target is `TARGNAME` (SN2023IXF), so the caption fell back to the file name. The error band is drawn, but this spectrum's median error is 0.76% of the flux, about 0.5 pt at the figure's scale: thinner than the 1 pt line. Rendered here to confirm. | `FITSFigureCaption` reads `OBJECT`, else `TARGNAME`, for images too. The spectrum names its error: "±1σ band from ERROR — median 0.8% of the flux", and says when the band is narrower than the line, rather than leaving the reader to look for it. The band's opacity rises so a thin band shows. |
| **D5** | 7.3, Search (Medium) | A TAP search on a dead host: `timedOut` is "transient", so the query is tried three times at 120 s each, about 6 minutes behind a spinner. | The TAP path does not retry after a timeout (the host has had two minutes), and has an overall budget. The Search screen says "Waiting for CADC — *n* s" with Cancel, and after a timeout "CADC's archive is not answering" (as `get_service_health` saw). `search_observations` answers the same. |

## Small items the report raised

| Step | Item | Fix |
|---|---|---|
| **N1** | D1's mistyped id | A lookup that misses names the id it most likely means: same length, or one digit added or dropped. It never acts on the guess. |
| **N2** | The Portal session card's Delete and Renew are not pointable | Each card's Delete and Renew are pointable targets, by session id. |
| **N3** | `2A7511B7-…`: a second `1525350` record under the slash form, with the 0-byte `pkg-….txt` file | R3 leaves it, rightly, as the corrected id is taken by `33AFFFB8-…`. It is marked as a duplicate of that record, in Research and in `list_downloaded_observations` (`duplicateOf`), for the person to delete. |
| **N4** | 1.1: the same failed delete appears twice on the bar, 5 s apart | A failed proposal stays in Pending for retry, and the person applied it again. The second attempt's task says "again". An apply that failed as "no such session" is not offered for retry. |
| **N5** | "`get_proposal_state` forgets failed proposals after ~5 min though the item stays in Pending" | *Not reproduced from the code:* a pending proposal's state is read from the live queue, not a tombstone, until it expires (3 h). What the pass likely saw is an auto-applied write that failed inline (e.g. `renew_session`), which is withdrawn, with the failure in the tool's answer. Handout 22 asks for the id and the times if it recurs. |

## Handout corrections (for handout 22)

- 1.4: name a slow image. `astroai/improc` took 240 s, while a warm cluster finishes most probes in 3–15 s.
- 1.5: make the apply fail with a destructive tool (`delete_session` of a made-up id), which waits in Pending. `renew_session` applies inline.
- Re-run with CADC up: 3.2, 4.2–4.5, 7.3, 7.5. Also 1.3's drift clause (stop, then start at another size) and 2.3 (the person deletes from the Portal).

## For the person

- `qa-person` (`q9p87ajc`) is still running: delete it from the Portal, which also completes 2.3.
- The pass's leftovers are in §5 of the report; each deletion goes through Pending.

## Decisions

1. **V:** set `MARKETING_VERSION` to 1.4.0 now, keep build 17 until an App Store upload, and add `buildCommit` to `describe_app`?
