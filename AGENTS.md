# Connecting an AI agent to Verbinal

This file is for AI assistants — Claude, Codex, Copilot, Cursor, Gemini or any other — that the person
using Verbinal has asked to connect to it. It is not about working on Verbinal's source code (see
`CONTRIBUTING.md` for that).

Verbinal is a Mac app for the Canadian Astronomy Data Centre and the CANFAR science platform: archive
search, FITS image and data-cube viewers, VOSpace storage, platform sessions and batch jobs, and Remote
Compute. Everything a person can do in it, an agent can do too: about two hundred tools, over the Model
Context Protocol (MCP).

## How it connects

- **A local stdio MCP server.** Your client launches Verbinal's own program with one argument, `mcp`.
  That process relays to the running Verbinal app over a socket inside Verbinal's sandbox container,
  which only this Mac user can reach.
- **No network port, no URL, no API key, no environment variables.**
- **Server name:** use `verbinal-canfar`. It is the name Verbinal's own setup uses.
- **Verbinal has to be running**, with external AI agents allowed.

## 1. Is Verbinal installed?

```sh
mdfind "kMDItemCFBundleIdentifier == 'com.codebg.Verbinal'"
```

This prints where the app is — usually `/Applications/Verbinal.app`. If it prints nothing, Verbinal is
not installed; it is free on the Mac App Store (search for Verbinal).

## 2. The person allows AI agents

The server is off until the person turns it on, and turning it on is their decision. Ask them to:

1. Open Verbinal.
2. Go to **Settings** (⌘,) ▸ **AI Agent**.
3. Turn on **Allow external AI agents**.

If their assistant is **Claude Desktop** or **Claude Code**, the **AI Assistant** tile on Verbinal's
home screen runs a wizard that does steps 2 to 4 for them. The user manual explains all of it to the
person, in English and French: [docs/manual/en/12-ai-assistant.md](docs/manual/en/12-ai-assistant.md).
The whole manual is online at https://szautkin.github.io/canfar-macos/, with an index for agents at
https://szautkin.github.io/canfar-macos/llms.txt and every page in Markdown.

## 3. The command

The server is the app's own executable, with the argument `mcp`:

```text
/Applications/Verbinal.app/Contents/MacOS/Verbinal mcp
```

Use the path `mdfind` printed, with `/Contents/MacOS/Verbinal` after it. **Settings ▸ MCP Clients**
shows the exact command for this Mac, and copies it — use that for a development build run from Xcode,
whose app is elsewhere.

## 4. Register it with your client

Every client needs the same three things:

- **Name:** `verbinal-canfar`
- **Command:** the full path to `Verbinal.app/Contents/MacOS/Verbinal`
- **Arguments:** `["mcp"]`

Add it to the client's configuration **without removing the servers already there**. Most clients need
a restart or a reload before a new server appears.

**Claude Code**

```sh
claude mcp add --transport stdio --scope user verbinal-canfar -- '/Applications/Verbinal.app/Contents/MacOS/Verbinal' 'mcp'
```

**Claude Desktop:** `~/Library/Application Support/Claude/claude_desktop_config.json`, or let Verbinal's
wizard write it

```json
{ "mcpServers": { "verbinal-canfar": { "command": "/Applications/Verbinal.app/Contents/MacOS/Verbinal", "args": ["mcp"] } } }
```

**OpenAI Codex:** `~/.codex/config.toml`

```toml
[mcp_servers.verbinal-canfar]
command = "/Applications/Verbinal.app/Contents/MacOS/Verbinal"
args = ["mcp"]
```

**These clients take the same `mcpServers` entry as Claude Desktop:**

- **Cursor:** `~/.cursor/mcp.json`
- **Gemini CLI:** `~/.gemini/settings.json`
- **Windsurf:** `~/.codeium/windsurf/mcp_config.json`

**VS Code (GitHub Copilot agent mode):** the user or workspace `mcp.json`

```json
{ "servers": { "verbinal-canfar": { "type": "stdio", "command": "/Applications/Verbinal.app/Contents/MacOS/Verbinal", "args": ["mcp"] } } }
```

**Any other client** that can launch a stdio MCP server works the same way.

## 5. Check it works

Call `describe_app`. It answers with the app's version and what it can do. While Verbinal is closed the
server still connects, and every tool answers that Verbinal is not running; once the person starts it,
the server finds it by itself and says its tool list has changed. If the call fails:

- **Is Verbinal running?** The server only relays to the app. It cannot start it.
- **Is Allow external AI agents on?** Settings ▸ AI Agent shows whether it is listening.
- **Is the command the app that is installed now?** A path to an app that has moved or been deleted
  fails to launch; Settings ▸ MCP Clients has the current one.
- **Still failing?** Settings ▸ AI Agent ▸ Diagnostics says what the server last did.

## Once you are connected

- **Start your session.** Call `start_session` first, saying who you are and your purpose. The
  person approves it in Verbinal and may give you instructions for the session: follow them. Its
  `session` id identifies every log entry of your session; `get_session_log` reads them. Without a
  session, no other tool works but `describe_app`.
- **Get your bearings.**
  - `describe_app` gives an overview; `list_apps` maps the tools by screen.
  - `list_workflows` and `use_workflow` give step-by-step protocols.
- **Work where the person can see it.**
  - `navigate_to` shows them the screen you are working on.
  - `list_ui_targets` names everything on screen, and the entries of every list.
  - `point_at_ui` points at the control you mean, and `show_ui_hints` puts several hints up at
    once — a numbered tour, if they want one.
  - `select_ui` selects a list's entry; `open_ui` opens a folded section, a hidden panel or a menu
    on purpose.
  - Hints never press anything. They are not the marks on an image (`annotate_fits`).
  - `list_activity` says what the app is doing, the same line as the activity bar at the bottom
    of the window.
- **The person reviews your changes.** Consequential changes are proposals.
  - With auto-apply on, reversible ones apply at once.
  - Destructive ones, such as deleting data or stopping a session, always wait for the person to
    approve them in the app.
  - `list_pending_proposals` shows what is waiting.
- **When something is slow or fails, read the log.** Verbinal keeps a log of your session: your calls
  with the CADC and CANFAR requests each made and what their outcomes mean, every change anyone made
  with who and why, and the app's decisions with their rules.
  - A reply that asked CADC, took a while or failed carries a `timing` block: a verdict, `retry`, and
    `logToken`.
  - `explain_log_entry` follows an entry's cause and effect; `get_session_log` gives the log and
    what is happening `now`.
  - After Verbinal restarts, `list_session_logs` finds your session from before.
  - Give every write a `why`: the person reads it with the change in Pending.
- **Signing in is theirs to do.** Portal, Remote Compute and Storage are the person's CADC/CANFAR
  account, and stay locked until they sign in.
  - Their tools answer that sign-in is required until then.
  - Never ask for their password. You cannot sign in for them.
- **Running code on CANFAR:** `run_code` runs Python or Bash in a session on their CANFAR account. It
  works only after they have chosen a compute image in Settings ▸ AI Compute, which is their decision
  and their allocation. The Remote Compute screen (`navigate_to remoteCompute`) explains how, and
  `get_compute_state` says where it stands.
