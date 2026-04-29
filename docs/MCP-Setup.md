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

```sh
log show --predicate 'subsystem == "com.codebg.Verbinal.agent"' --last 5m
```

Each tool call emits one `audit` entry with the request id, origin, tool
name, verb class, outcome, duration, and a SHA-256 hash of the args (bodies
are never logged).

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
