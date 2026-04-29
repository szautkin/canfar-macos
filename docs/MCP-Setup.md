# MCP Setup — pointing an AI client at Verbinal

Verbinal exposes its features over the Model Context Protocol (MCP) so an AI
client like Claude Desktop can search the CADC archive, read observation
metadata, propose downloads, and prepare science-platform sessions on the
user's behalf — under user-confirmed control via the proposal strip.

## How it's wired

```
┌─────────────────┐    stdio (ndjson)    ┌──────────────┐    AF_UNIX socket    ┌─────────────────┐
│  Claude Desktop │  ─────────────────►  │  canfar-mcp  │  ───────────────►   │  Verbinal app   │
│ (or other MCP   │                      │   (helper)   │                      │  (sandboxed)    │
│  client)        │                      └──────────────┘                      └─────────────────┘
└─────────────────┘                            ▲                                       │
                                               │  reads sidecar                        │  writes sidecar
                                               │  with socket path                     │  on listener open
                                               ▼                                       ▼
                                    ~/Library/.../com.codebg.Verbinal/mcp.sock-path
```

- **Helper binary**: `Verbinal.app/Contents/Resources/canfar-mcp`. Stateless
  forwarder: reads the sidecar, connects to the app's unix socket, splices
  bytes between stdio and the socket.
- **App listener**: `AgentsService` opens an AF_UNIX socket inside the app's
  Application Support container when "Allow external AI agents" is on
  (Settings ▸ Agents). Writes the path to a sidecar file the helper reads.

The listener uses POSIX `socket(AF_UNIX, SOCK_STREAM, 0)` directly rather
than `Network.framework`. `NWParameters.tcp` over a unix endpoint still
trips the sandbox's `network.server` policy and fails to bind under MAS;
plain POSIX `bind()` to a path inside our own container is filesystem-only
and is permitted by the default sandbox profile.

## Setup (one-time)

### 1. Enable the server in Verbinal

1. Open Verbinal.
2. **Settings ▸ Agents**.
3. Toggle "Allow external AI agents" on.
4. The status row should show "Listening" with a path under
   `~/Library/Containers/com.codebg.Verbinal/Data/Library/Application Support/com.codebg.Verbinal/mcp-<pid>.sock`.

### 2. Locate the helper binary

Pick whichever one matches the build you're running:

| Build              | Helper path                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------------ |
| Local Debug        | `~/Library/Developer/Xcode/DerivedData/Verbinal-*/Build/Products/Debug/Verbinal.app/Contents/Resources/canfar-mcp` |
| Local Release      | `~/Library/Developer/Xcode/DerivedData/Verbinal-*/Build/Products/Release/Verbinal.app/Contents/Resources/canfar-mcp` |
| Installed (MAS)    | `/Applications/Verbinal.app/Contents/Resources/canfar-mcp`                                                   |

Resolve any symlinks first (Claude Desktop wants an absolute path):

```sh
readlink -f "$(find ~/Library/Developer/Xcode/DerivedData -name canfar-mcp -path '*/Verbinal.app/*' 2>/dev/null | head -1)"
```

### 3. Configure your MCP client

#### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (create
if absent) and add:

```json
{
  "mcpServers": {
    "verbinal": {
      "command": "/absolute/path/to/Verbinal.app/Contents/Resources/canfar-mcp"
    }
  }
}
```

Replace the `command` value with the absolute path from step 2. Restart
Claude Desktop. The Verbinal tool surface (`describe_app`, `search_observations`,
`launch_session`, etc.) should appear in the tools picker.

#### Other MCP clients

Any client that spawns a subprocess and pipes JSON-RPC over stdio will work.
Point it at the helper binary; no flags needed. The helper reads the sidecar
on launch and connects automatically.

## Verifying the connection

From Claude (or any MCP client):

1. Call `describe_app` — should return a prose brief and the server version.
2. Call `get_auth_state` — returns whether the user is signed into CADC.
3. Call `list_pending_proposals` — should return `{"proposals": []}` on a
   fresh session.

If `describe_app` errors with code `-32000` ("Verbinal app is not running"),
either the toggle in Settings ▸ Agents is off, or the helper can't read the
sidecar. Check:

```sh
cat "$HOME/Library/Containers/com.codebg.Verbinal/Data/Library/Application Support/com.codebg.Verbinal/mcp.sock-path"
```

The path printed should be a `.sock` file that exists and is readable.

## Watching live activity

There are three independent log streams; each gives you a different
view of the same request flowing through.

### 1. Cowork-side (full JSON, slow refresh)

```sh
tail -F ~/Library/Logs/Claude/mcp-server-verbinal-canfar.log
```

This is what Claude Cowork itself records. Every JSON-RPC message in
both directions is dumped verbatim, plus stderr from the helper. Use
this when you need to see raw payloads — e.g. a tool's full response
content or schema validation errors from the client side.

### 2. Helper-side (concise per-frame trace)

The helper's stderr is folded into the same Cowork log (look for
`[canfar-mcp]` lines), but the *content* is one line per frame:

```
2026-04-29T... [canfar-mcp] [info] startup pid=12345
2026-04-29T... [canfar-mcp] [info] sidecar resolved -> /Users/.../mcp-12345.sock
2026-04-29T... [canfar-mcp] [info] socket connected
2026-04-29T... [canfar-mcp] [info] entering forward loop
2026-04-29T... [canfar-mcp] [debug] stdio→socket 312B method=initialize id=0
2026-04-29T... [canfar-mcp] [debug] socket→stdio 478B response result id=0
2026-04-29T... [canfar-mcp] [debug] stdio→socket 56B method=notifications/initialized id=-
2026-04-29T... [canfar-mcp] [debug] stdio→socket 49B method=tools/list id=1
2026-04-29T... [canfar-mcp] [debug] socket→stdio 12347B response result id=1
```

Filter just the helper's own lines:

```sh
grep '\[canfar-mcp\]' ~/Library/Logs/Claude/mcp-server-verbinal-canfar.log | tail -F
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
| Cowork says "tools not visible"          | `bridge` log: did `tools/list` even arrive? If not, helper didn't connect.                                        |
| `notifications/initialized` errors       | `bridge` log should say `ignoring notification … (no id)`. If it shows `method not found`, you're on an old build. |
| Listener fails to start                  | Settings ▸ Agents row shows the real reason (now that `MCPTransportError` conforms to `LocalizedError`).            |
| Helper can't connect to socket           | `mcp-server-verbinal-canfar.log`: `[canfar-mcp] [error] connect failed —`                                          |
| Specific tool call fails                 | `bridge`: `tools/call <name> -> failed (<tag>)`. `audit`: same row with the failure tag.                           |

## Notes for MAS submission

- The helper executable is signed with the host app's signing identity at
  build time and lives inside the `.app` bundle. No separate notarisation
  step is needed.
- The helper does **not** require any sandbox entitlement — it runs in the
  user's space when spawned by an MCP client.
- The host app uses POSIX `bind(2)` on a path inside its own
  `~/Library/Containers/<bundle>/Data/...` Application Support container.
  This requires no `network.server` entitlement and is permitted by the
  default MAS sandbox profile.
