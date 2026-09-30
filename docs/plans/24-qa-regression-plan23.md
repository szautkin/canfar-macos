# QA handout — regression pass for plan 23 (the session log)

**Date:** 2026-09-30
**Build:** `release/1.4.0` @ `7fa5df5` or later. `describe_app` must say `serverVersion: "1.4.0"`; record
its `buildCommit` (a `+` means uncommitted changes).
**Audience:** the MCP QA pass (an assistant connected to Verbinal, with the person watching). ~1½ hours.
**Related:** [Plan 23](./23-agent-session-log.md) · [Handout 22](./22-qa-regression-plan21.md)

This pass checks what plan 23 built:

- the session log, and the three tools that read it
- the timing note on replies
- the `why` on every write
- the app's decisions and their rules
- managing the logs, in Settings and by tools
- tool deadlines that follow the request timeouts
- the fix to `delete_session` for every session type

Record each case as **PASS / FAIL / BLOCKED**, and attach the tool's JSON for a FAIL.

The person's standing rules still hold:

- No headless jobs unless the person directs one.
- Nothing is stored on this Mac unless the case says so and the person agrees.
- Destructive changes wait in Pending, for the person to apply.

**Record ids and tokens exactly as the tools give them.**

## Setup

1. Build and run Verbinal from `release/1.4.0`; sign in to CADC.
2. `describe_app`: record `serverVersion` and `buildCommit`. Its brief has a section "When something
   is slow or fails — the session log".
3. Settings ▸ AI Agent: **Allow external AI agents** and **Auto-apply** on. A **Session Logs**
   section is there.

---

## 1. The log and its tools

| # | Steps | PASS if |
|---|---|---|
| 1.1 | `list_session_logs`. | This session is listed with `isThisSession: true` and `open: true`; `retention` says 10 days and 10 MB. |
| 1.2 | `get_session_log`. | The first entry is `opened`: your client, Verbinal's version and commit, macOS, Auto-apply, signed in. `now` is present. Every entry has a `line`, and the tokens rise. |
| 1.3 | `search_observations` for M31 (maxRec 5); then `get_session_log` `only: "calls"`. | The call's entry nests its request (`cadc-tap`, seconds, `ok`); the line reads "Called search_observations — answered, in … The CADC archive search answered in …". |
| 1.4 | `get_session_log` with `since` = 1.2's `nextToken`. | Only what came after; `expired: false`. |
| 1.5 | `get_session_log` `about: "cadc-tap"`, then `text: "search"`, then `who: "assistant"`. | Each narrows as it says. |

## 2. The timing note

| # | Steps | PASS if |
|---|---|---|
| 2.1 | 1.3's reply. | A second text block `{"timing": …}` with `requests`, `verdict`, `logToken`; the first block is the search's JSON as before. |
| 2.2 | `get_auth_state`. | One block: no note on a quick local answer. |
| 2.3 | `explain_log_entry` with 2.1's `logToken`. | The call's entry whole, and a `story`. |
| 2.4 | Only if CADC is slow or down at the time: any search. | The verdict names the archive search and what its outcome means, with `retry: "later"`; `get_service_health` → `seenByApp.cadc-tap` has the failure. Otherwise BLOCKED. |

## 3. Why, who, and the app's rules

| # | Steps | PASS if |
|---|---|---|
| 3.1 | `man delete_session`. | Its schema has `why` (one sentence) and `app`. `man search_observations` has no `why`. |
| 3.2 | The person launches a throwaway notebook `qa-log`. Propose `delete_session` for it with `why: "throwaway from the QA pass"`. | Pending shows the change with **Why: throwaway from the QA pass**. The log has a decision: "… waits in Pending: a delete always waits for the person …". |
| 3.3 | The person applies it; `get_session_log` `only: "actions"`. | "Deleted session … — by the assistant, applied by the person, because: throwaway from the QA pass. Done in …". |
| 3.4 | `explain_log_entry` on 3.3's action. | Its causes: the decision and your call. The story runs from the call to the change. |
| 3.5 | The person makes a folder `qa-log-folder` in Storage, and saves a query. | Two actions "by the person". |
| 3.6 | `save_query` a trivial query with a `why` (Auto-apply on). | A decision "applied at once: Auto-apply is on …" and an action with your why. |

## 4. Deleting sessions of every type (the person's report)

| # | Steps | PASS if |
|---|---|---|
| 4.1 | The person launches a desktop session and opens an app in it (e.g. ds9). `list_sessions`. | `desktopApps` lists the app, with its desktop's `session` id and its own `app` id. |
| 4.2 | `delete_session` with the desktop's `id` and the app's `app`; the person applies it. | Only the app stops; the desktop still runs. The log says "Stopped desktop app …" (as a `delete_desktop_app` action). |
| 4.3 | `delete_session` for the desktop; the person applies it. | The desktop and any apps left in it end. |
| 4.4 | A finished batch job from the leftovers (e.g. `keqh41rx`), if still listed: `delete_session`; the person applies it. | It is gone from `list_headless_jobs`. |
| 4.5 | The Background Jobs sheet's delete on a finished job, and the Portal's delete on the throwaway. | Each returns once the platform no longer runs it; the list is right at once, with no fixed wait. |

## 5. Managing the logs

| # | Steps | PASS if |
|---|---|---|
| 5.1 | Settings ▸ AI Agent ▸ **Show Session Logs…**. | This session is listed as **Open**. Its lines match `get_session_log`'s; **Changes** shows the actions only; a call opens to its requests. |
| 5.2 | `export_session_log` (text). | The reply names a file in Downloads. The file heads the session with its header, then its lines. The log has the export as an action. |
| 5.3 | In the view: select this session. | **Delete…** is disabled for an open session. |
| 5.4 | Quit Verbinal and relaunch; reconnect; `list_session_logs`. | The earlier session is closed with `ending: "verbinalQuit"` (or `disconnected`), and a new one is open. `get_session_log` with the earlier `session` reads it. |
| 5.5 | `delete_session_logs` with the earlier session's id; the person applies it. | It waits in Pending (destructive), and afterwards it is gone. `delete_session_logs` with this session's id is refused. |

## 6. Deadlines

| # | Steps | PASS if |
|---|---|---|
| 6.1 | `list_activity` while a download or probe runs, if one does. | The running task has `waitingOn`: "… had waited N s of its 120 s". Otherwise BLOCKED. |
| 6.2 | `man list_sessions`, then `get_session_log` `only: "decisions"`. | No read tool now stops at 30 s (the description no longer mentions it). Any deadline decision in the log names what was waiting. |

## Leftovers

List everything this pass creates, each deletion through Pending:

- notebook `qa-log`, if 3.3 did not end it
- the desktop from 4.1, if 4.3 did not end it
- folder `qa-log-folder`, and the saved queries from 3.5 and 3.6
- the exported log file in Downloads (the person's to delete)
