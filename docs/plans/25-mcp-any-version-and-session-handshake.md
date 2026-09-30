# Plan 25 — Any MCP version; a session the person approves

**Date:** 2026-09-30
**Branch:** `release/1.4.0` (after plan 23, `b8110da`)
**Asked for** (the person, 2026-09-30):

- "Verbinal should accept any version of the MCP"
- "we still have to instruct the AI agent that we can provide the session id and do shake/ack on the
  app side"
- "the purpose is to identify any logs for the AI agent session — simplify"
- "make it mandatory for the agent"
- "on start_session, open a modal dialog to inform the user that an agent wants to start a session,
  and let the user add custom instructions (say 250 words) for the session — or use a default, such
  as use only this app and its tools, no other external apps or network connections"
- "show the user the agent's name, and some info on how the agent presents itself"

## Status

| Step | State | Commit |
|---|---|---|
| P plan | done — decisions taken | |
| V any MCP version (app and relay) | done — `MCPProtocol`; `server/discover`; cancellation reaches the call | (this commit) |
| S `start_session`: the person approves; the session id and its instructions | not started | |
| M no session, no tools | not started | |
| W words for the assistant, handout | not started | |

## Why

- **MCP 2026-07-28 removed the handshake and sessions.** Verbinal, which needs `initialize`, fails
  against a client that speaks only the new version.
- **The session log (plan 23) keys everything by an id the assistant never sees.**
- **No one asks the person** whether this assistant may work in Verbinal now, or on what terms.

## V — Any MCP version

Verbinal and its relay answer both old and new clients.

- **Old (`initialize` … 2025-11-25):** as today.
- **New (2026-07-28):**
  - `server/discover` answers the versions, the capabilities, the identity and the instructions,
    from one text shared with `initialize`.
  - The version is read from each request's `_meta`; an unsupported one answers `-32022`.
  - Results carry `resultType` and the server's identity; list results carry `ttlMs` and
    `cacheScope`.
- **The relay** does the same while the app is closed.
- **A session is one connection,** in both versions: the relay holds one connection to the app for
  its one assistant. A new-version client, which has no handshake, is still one connection.
- **`notifications/cancelled`** cancels the call it names, in both versions, so an assistant that
  stops waiting ends what it waited for.

## S — `start_session`: the person approves

The assistant's first call. It says who it is:

| Argument | What it is |
|---|---|
| `agent` | its name, e.g. "Claude" |
| `model` | optional, e.g. "claude-opus-5-5" |
| `purpose` | one sentence: what it is here to do |

**The approval window.** Verbinal comes forward and opens a window:

- "An assistant wants to start a session".
- The client as the connection names it (`claude-code/2.1`), its MCP version, and the time.
- How the assistant presents itself — its name, model and purpose — marked as what the assistant
  says of itself.
- **Session instructions:**
  - a text of up to 250 words, counted as you type;
  - filled with the default: "Use only Verbinal and its tools for this work: no other apps, and no
    network connections outside Verbinal. Ask before anything destructive." (decision 2).
- **Allow** or **Deny**.

**Allowed:** the call answers

- `session`: the id every entry of this session's log carries;
- `instructions`: the person's text, word for word, for the assistant to follow for the whole
  session;
- how to read the log (`get_session_log`).

The log's header keeps the assistant's self-description and the instructions, and the Session Logs
view shows them. Calling `start_session` again answers the same session, without asking again.

**Denied:** the call fails, saying so ("The person declined the session"), and the log records it.
The assistant may ask again later. **No answer:** the window waits as long as the assistant does;
if the assistant stops waiting, the window closes.

**Every reply carries the session id** (`_meta` `com.codebg.verbinal/session`, and the timing note),
so any reply matches its log entries.

**What Verbinal enforces, and what it does not:** it cannot stop an assistant from using its other
tools or connections outside Verbinal. The instructions reach the assistant as words to follow;
Verbinal enforces its own side (M), and the log keeps everything the session did, against the
instructions it was given.

## M — No session, no tools

- Until the person allows a session, every call but `start_session` fails:
  - `sessionRequired`: "No session: call start_session first — the person approves it in Verbinal."
  - `describe_app` answers too, so an assistant can learn what to do (decision 1).
- Each connection needs its own session. An assistant that reconnects after Verbinal restarts
  starts again, and the person is asked again.
- The in-app assistant is not affected.

## W — Words for the assistant

- **One instruction** in both MCP versions' answers, `describe_app` and `AGENTS.md`:
  - "Call `start_session` first, saying who you are and your purpose. The person approves it in
    Verbinal and may give you instructions for the session: follow them.
  - Its `session` id identifies every log entry of your session; `get_session_log` reads them.
  - Without a session, no other tool works."
- **Changelog** entries.
- **Handout 26** for QA:
  - an old and a new client;
  - Allow, Deny, and no answer;
  - edited instructions reaching the assistant;
  - a call before the session refused;
  - the id on replies and in the log.

## Decisions

Taken by the person, 2026-09-30:

1. **Before a session,** `start_session` and `describe_app` work, and nothing else.
2. **The default instructions** are editable in Settings ▸ AI Agent, and fill every window.
3. **No answer:** the window waits as long as the assistant waits. `start_session` is exempt from
   the router's deadline. If the assistant stops waiting — it cancels, or its connection closes —
   the window closes by itself, and the log records it.
