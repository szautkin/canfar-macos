# QA handout — regression pass for plan 25 (every MCP version; the session handshake)

**Date:** 2026-09-30
**Build:** `release/1.4.0` at the plan 25 W commit or later. `describe_app` must say `serverVersion: "1.4.0"`;
record its `buildCommit` (a `+` means uncommitted changes).
**Audience:** the MCP QA pass (an assistant connected to Verbinal, with the person watching), and the
person, for the window and a Terminal. ~1 hour.
**Related:** [Plan 25](./25-mcp-any-version-and-session-handshake.md) · [Handout 24](./24-qa-regression-plan23.md)

This pass checks what plan 25 built:

- `start_session`: the assistant's handshake, and the window where the person allows it;
- the person's instructions for the session, and their default in Settings;
- no session, no tools;
- the session id on every reply and in the log;
- every MCP version, 2026-07-28 included, from the app and from its relay while the app is closed.

Record each case as **PASS / FAIL / BLOCKED**, and attach the tool's JSON for a FAIL.

The person's standing rules still hold:

- No headless jobs unless the person directs one.
- Nothing is stored on this Mac unless the case says so and the person agrees.
- Destructive changes wait in Pending, for the person to apply.

**Only the person clicks Allow or Deny.** The assistant says what it expects, then waits.

## Setup

1. Build and run Verbinal from `release/1.4.0`; sign in to CADC.
2. Settings ▸ AI Agent: **Allow external AI agents** and **Auto-apply** on. A **Session
   Instructions** section is there, above Session Logs, showing "Use only Verbinal and its tools for
   this work: no other apps, and no network connections outside Verbinal. Ask before anything
   destructive."
3. Restart the assistant's MCP client, so this pass starts on a new connection.

---

## 1. No session, no tools

| # | Steps | PASS if |
|---|---|---|
| 1.1 | Before anything else: `get_auth_state`. | It fails: the text begins "sessionRequired: No session — call start_session first, saying who you are and your purpose." The reply's `_meta` has `com.codebg.verbinal/session`, a UUID. |
| 1.2 | `describe_app`. | It answers. The brief has a **Start here** section: "Call `start_session` first, saying who you are and your purpose. The person approves it in Verbinal …". |
| 1.3 | `list_session_logs`, `navigate_to`, `search_observations` — each once. | Each fails with `sessionRequired`, as in 1.1. Nothing changes on screen. |

## 2. The handshake

| # | Steps | PASS if |
|---|---|---|
| 2.1 | `start_session` with `agent` (your name), `model` (if you know it) and `purpose` (one sentence). The person looks, and does not answer yet. | Verbinal comes forward with a window, "An assistant wants to start a session". **Client** is your client as its connection names it; **Connection** is "MCP" and a version; **Asked** is the time. The box "How the assistant presents itself" shows your name · model and your purpose, with "As the assistant describes itself — Verbinal cannot check it." The instructions are the default from Setup 2, with the word count below. The call has not answered. |
| 2.2 | The person waits a minute, then clicks **Allow** without editing. | The call answers `session` (a UUID, the same as 1.1's `_meta`), `instructions` (the default, word for word), `allowedAt`, and `log`. The window closes. |
| 2.3 | `get_auth_state`, then `get_current_view`. | Both answer, and each reply's `_meta` `com.codebg.verbinal/session` is 2.2's `session`. |
| 2.4 | `get_session_log`. | An entry of kind `started`: "The person allowed the session of <your name> (<model>), as the assistant presents itself, here to: <purpose> — with these instructions: <the default>". `who` is the person. |
| 2.5 | `list_session_logs`. | The entry with `isThisSession: true` has `session` equal to 2.2's `session`. |
| 2.6 | `start_session` again, with the same arguments. | It answers at once with the same `session` and `instructions`, and no window. `get_session_log` has one `started` entry, not two. |

## 3. The person's say

For each case, restart the assistant's MCP client first, so it has a new connection and a new session.

| # | Steps | PASS if |
|---|---|---|
| 3.1 | `start_session`. The person replaces the instructions with "Only read; change nothing." and clicks **Allow**. | `instructions` is "Only read; change nothing." exactly. The assistant says it will follow them. |
| 3.2 | `start_session`. The person pastes more than 250 words into the instructions. | The count turns red, and **Allow** is disabled. **Reset** brings back the default, and **Allow** works again. The person clicks **Allow**. |
| 3.3 | `start_session`. The person clicks **Deny** (or presses Esc). | The call fails with `sessionDeclined`: "The person declined the session in Verbinal. Ask them in the conversation before calling start_session again." The window closes. Any other tool still fails with `sessionRequired`. In Settings ▸ AI Agent ▸ Session Logs, that session's log says "The person declined the session of …". |
| 3.4 | `start_session`; while the window is up, the assistant's client cancels the call (the client's stop or Esc). If the client cannot cancel, the person quits the client instead. | The window closes by itself. In Session Logs, that session's log says "<your name> stopped waiting before the person answered its session." Record which way was used. |
| 3.5 | The person sets Settings ▸ AI Agent ▸ Session Instructions to "Stay in Verbinal. Tell me before each download." Then the assistant calls `start_session`. | The window starts with that text. After **Allow**, `instructions` is that text. |
| 3.6 | The person clicks **Reset** under Session Instructions in Settings. | The built-in default is back, and the next window starts with it. |
| 3.7 | Two clients at once (for example Claude Code and Claude Desktop), each calling `start_session`. | One window at a time; when the first is answered, the second appears. Each client gets its own `session`. BLOCKED if only one client is available. |

## 4. Every MCP version

These cases use a Terminal. `V` is the app's command, as Settings ▸ MCP Clients shows it (for example
`/Applications/Verbinal.app/Contents/MacOS/Verbinal`). Each command keeps its input open for three
seconds, so the answer can arrive.

| # | Steps | PASS if |
|---|---|---|
| 4.1 | The version your assistant's client speaks: 2.1's **Connection**. | Record it (for example "MCP 2025-06-18"). |
| 4.2 | With Verbinal running: `(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"qa","version":"1"}}}}'; sleep 3) \| "$V" mcp` | One JSON line: `result.supportedVersions` starts with "2026-07-28" and includes "2025-06-18"; `result.resultType` is "complete"; `result.instructions` begins "Call `start_session` first". |
| 4.3 | As 4.2, but with the method `tools/call`, `"name":"get_auth_state","arguments":{}` in `params` next to `_meta`. | `isError: true`, with the `sessionRequired` text, and `_meta` names a session: a modern client needs a session too. |
| 4.4 | As 4.2, with the protocol version "2099-01-01". | An error with code `-32022`, listing the supported versions. |
| 4.5 | Quit Verbinal. Repeat 4.2. | `result.instructions` begins "Verbinal is not running." and goes on "Call `start_session` first, …". |
| 4.6 | Quit Verbinal. `(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qa","version":"1"}}}'; sleep 3) \| "$V" mcp` | `result.protocolVersion` is "2024-11-05", and `result.instructions` is as in 4.5. Reopen Verbinal after this case. |

## 5. The words

| # | Steps | PASS if |
|---|---|---|
| 5.1 | Read `AGENTS.md` ▸ "Once you are connected". | Its first bullet, **Start your session**, says what 1.2's **Start here** says, word for word. |
| 5.2 | `man start_session`. | Its description says to call it first, that it waits for the person, that it answers `session` and `instructions`, and what `sessionDeclined` means. |
| 5.3 | The AI Guide: find `start_session`. | It is listed with the session log's tools. |

## Report

For each FAIL: the case, the tool's JSON or the Terminal's line, and what the window showed (a
screenshot helps). Note the client and its MCP version from 4.1.
