# MCP Setup — pointing an AI client at Verbinal

Verbinal exposes its features over the Model Context Protocol (MCP) so an AI
client like Claude Desktop can search the CADC archive, read observation
metadata, propose downloads, and prepare science-platform sessions on the
user's behalf — under user-confirmed control via the proposal strip.

## How it's wired

```
┌─────────────────┐   stdio (ndjson)   ┌──────────────────────────┐   AF_UNIX socket   ┌───────────────┐
│  Claude Desktop │  ───────────────►  │  Verbinal mcp            │  ───────────────►  │ Verbinal app  │
│ (or other MCP   │                    │  (the app's own binary,  │                    │ (sandboxed,   │
│  client)        │                    │   run as a bridge)       │                    │  running)     │
└─────────────────┘                    └──────────────────────────┘                    └───────────────┘
```

- **The command** is the app's own executable with the argument `mcp`:
  `Verbinal.app/Contents/MacOS/Verbinal mcp`. Run that way, it does not open
  a window: it relays between the client's stdio and the running app's
  socket (`Verbinal/MCP/MCPStdioBridge.swift`, which says why this is the
  main binary and not a separate helper — a bundled helper cannot run under
  Mac App Store signing). The old `canfar-mcp` helper is gone.
- **The app listener**: `AgentsService` opens an AF_UNIX socket in the app's
  App Group container when **Allow external AI agents** is on
  (Settings ▸ AI Agent).

The listener uses POSIX `socket(AF_UNIX, SOCK_STREAM, 0)` directly rather
than `Network.framework`. `NWParameters.tcp` over a unix endpoint still
trips the sandbox's `network.server` policy and fails to bind under MAS;
plain POSIX `bind()` to a path inside our own container is filesystem-only
and is permitted by the default sandbox profile.

## Setup (one-time)

`AGENTS.md` at the top of the repository is the setup for any client,
written for the assistant doing it. In short:

1. **Settings ▸ AI Agent ▸ Allow external AI agents** — the status row
   should show it listening.
2. **Settings ▸ MCP Clients** shows the command for this build (a Debug
   build from Xcode lives under DerivedData) and copies the
   `claude mcp add` line; the **AI Assistant** home tile runs a wizard that
   writes Claude Desktop's config.
3. Register it under the name `verbinal-canfar` with the command above and
   the arguments `["mcp"]`, for example in
   `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "verbinal-canfar": {
      "command": "/Applications/Verbinal.app/Contents/MacOS/Verbinal",
      "args": ["mcp"]
    }
  }
}
```

"Could not attach to MCP server verbinal-canfar" almost always means the
command points at an app that is no longer there (an old DerivedData build,
a moved app): point it at the one installed now and restart the client.

## Verifying the connection

From Claude (or any MCP client):

1. Call `describe_app` — should return a prose brief and the server version.
2. Call `start_session` with your `agent` name and `purpose` — Verbinal
   shows a window asking the person; once they allow it, the call answers
   the session's id and the person's instructions. Until then, every tool
   but these two answers `sessionRequired`.
3. Call `get_auth_state` — returns whether the user is signed into CADC.
4. Call `list_pending_proposals` — should return `{"proposals": []}` on a
   fresh session.

While Verbinal is closed the server still answers, and every tool says the
app is not running; once it starts, the bridge connects by itself and the
client is told the tool list changed. If tools keep saying so with the app
open, **Allow external AI agents** is off (Settings ▸ AI Agent), or the
bridge cannot reach the socket — its own log says which (below).

## Watching live activity

There are three independent log streams; each gives you a different
view of the same request flowing through.

### 1. Cowork-side (full JSON, slow refresh)

```sh
tail -F ~/Library/Logs/Claude/mcp-server-verbinal-canfar.log
```

This is what Claude Cowork itself records. Every JSON-RPC message in
both directions is dumped verbatim, plus stderr from the bridge. Use
this when you need to see raw payloads — e.g. a tool's full response
content or schema validation errors from the client side.

### 2. Bridge-side (concise per-frame trace)

The bridge's stderr is folded into the same Cowork log (look for
`[verbinal-mcp]` lines), but the *content* is one line per frame:

```
2026-09-27T... [verbinal-mcp] [info] mcp bridge startup pid=12345
2026-09-27T... [verbinal-mcp] [info] connected to /Users/.../mcp-6789.sock
2026-09-27T... [verbinal-mcp] [info] mcp bridge shutting down
```

Filter just the bridge's own lines:

```sh
grep '\[verbinal-mcp\]' ~/Library/Logs/Claude/mcp-server-verbinal-canfar.log | tail -F
```

### 3. App-side (live `os.log` stream)

The bridge service emits structured logs via Apple's unified logging.
Stream them in real time:

```sh
log stream --level debug \
  --predicate 'subsystem == "com.codebg.Verbinal.agent"'
```

You'll see lines from three categories:

- **`bridge`** — connection lifecycle, every `recv`/`send` frame, every
  method dispatch. `recv tools/call id=3 (124 bytes)` →
  `tools/call search_observations (124 bytes args)` →
  `tools/call search_observations -> data (4280 bytes)` →
  `send tools/call id=3 (4296 bytes, ok)`.
- **`audit`** — one line per dispatch: `request_id=… origin=… tool=… class=… outcome=… ms=… hash=…`.
- **`service`** — `AgentsService` lifecycle (listener start/stop, sidecar path).

Combine streams in one terminal:

```sh
log stream --level debug --predicate 'subsystem == "com.codebg.Verbinal.agent"' &
tail -F ~/Library/Logs/Claude/mcp-server-verbinal-canfar.log &
```

### What to look for when something's off

| Symptom                                  | Where to check                                                                                                    |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Cowork says "tools not visible"          | `bridge` log: did `tools/list` even arrive? If not, the bridge didn't connect.                                        |
| `notifications/initialized` errors       | `bridge` log should say `ignoring notification … (no id)`. If it shows `method not found`, you're on an old build. |
| Listener fails to start                  | Settings ▸ AI Agent row shows the real reason (now that `MCPTransportError` conforms to `LocalizedError`).            |
| Bridge can't connect to socket           | `mcp-server-verbinal-canfar.log`: `[verbinal-mcp] [info] connect to … failed —`                                    |
| Specific tool call fails                 | `bridge`: `tools/call <name> -> failed (<tag>)`. `audit`: same row with the failure tag.                           |

## Notes for MAS submission

- The bridge is the app's own executable run with `mcp`, so it carries the
  bundle's provisioning profile and its full sandbox, and reaches the App
  Group socket under distribution signing. There is no separate helper to
  sign or notarise.
- The host app uses POSIX `bind(2)` on a path inside its own container.
  This requires no `network.server` entitlement and is permitted by the
  default MAS sandbox profile.
