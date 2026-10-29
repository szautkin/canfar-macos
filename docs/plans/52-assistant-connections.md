# Plan 52 — Assistant connections: how to connect, what is connected, and closing what should not be

**Status: in progress on branch `1_4_2`.** History:
- Planned 2026-10-28.
- The same day the person said "keep 1_4_2 and proceed; do not forget DRY Orthogonality ETC SOLId and
  other relevant principles from the Progmatic programmer is a must". That takes every recommended answer
  for D1–D7, and builds all of it in 1.4.2.

The person (2026-10-28): "another thing we need to add ai connection prompts some where where user/ or ai
machine use feature can see them to connect to the mcp bridge; also, we want to shutdown those bridges
and do not let them dangling around ... the idea simplify connection and control their life cycle and
monitor them; review and plan it within this branch fix".

Words used here:
- **Bridge:** one `Verbinal mcp` process. An assistant's client launches it as its MCP server; it relays
  between the client's stdio and the running app's socket (`MCPStdioBridge`, `ResilientBridge`).
- **Connection:** the bridge's socket connection to the running app.
- **Session:** the assistant's approved session (plan 25). It belongs to the bridge, and survives
  Verbinal restarts while the bridge lives (plan 34 S).

## What the review found

1. **Nothing in Verbinal shows the bridges, and nothing can close one.**
   - On this Mac now there are two bridges:
     - pid 5206, launched 35 hours ago by `claude --permission-mode auto` (Claude Code);
     - pid 37662, launched 14 hours ago by the Codex app.
   - Both still have their parents, so neither is orphaned. But Verbinal knows only `connectionCount`:
     Settings shows "2 active".
   - **End Session** ends a session but not its bridge.
   - Turning **Allow external AI agents** off stops the listener, but the bridges stay and retry (3).
2. **Every Verbinal launch leaves a socket file behind, and every bridge tries them all.**
   - Each launch listens at a new `mcp-<pid>.sock` in the group container. `SocketServer.stop()` removes
     it, but only when the person turns AI agents off. Nothing stops the server at quit, so quitting,
     a crash or stopping a build in Xcode leaves the file.
   - While Verbinal is away, the bridge's fallback (plan 36 2.4) tries the sidecar, then every other
     `mcp-*.sock`, every 2 seconds, and logs one line per failure.
   - The group container held **311 `mcp-*.sock` files, 1 of them listening** (the S1–S3 spike,
     2026-10-28).
   - The result is in Claude Desktop's log of this server: `~/Library/Logs/Claude/mcp-server-verbinal-canfar3.log`
     reached **3.5 GB** (12–15 Oct). A 2 MB sample is all `connect to …/mcp-<pid>.sock failed — Connection
     refused`, for hundreds of different pids, each tried 31–42 times.
3. **A bridge waits for Verbinal every 2 seconds, forever.** While Verbinal is closed or AI agents are
   off, there is no backoff and no watch for the app coming back: only the timer.
4. **A refused bridge would say the wrong thing.**
   - When the app refuses its replayed handshake (`sessionNotApproved`), the bridge stops reconnecting
     but lives on. It then answers every call "Verbinal is not running", which is untrue.
   - Today the app passes `.allowAll`, so this path never runs. A person declining a session is
     `start_session`'s `sessionDeclined`, which the bridge never sees.
5. **A bridge does not watch its parent.**
   - It ends only when its stdin closes. A client that dies without closing the pipe leaves the bridge
     running: a grandchild may hold the pipe, or the client may hang.
   - None is orphaned today, but the bridge never checks.
6. **Connection help covers two clients, and nothing speaks to the assistant.**
   - The wizard (Home ▸ AI Assistant, Help ▸ Connect an AI Agent…) and Settings ▸ MCP Clients cover
     only Claude Desktop and Claude Code.
   - Codex (connected here), Cursor, Gemini CLI, Windsurf and VS Code are only in AGENTS.md on GitHub and
     the manual.
   - There is no prompt to paste into an assistant. Nothing on screen is written for an assistant that
     uses computer use to read it.

## Goals

- **G1. No bridge outlives its client.** None spins while Verbinal is away, no socket files pile up,
  and the logs stay quiet.
- **G2. One place shows every connected assistant, live, with Close.** It names the client, the
  bridge, its parent, its session and when it last called.
- **G3. Connecting any assistant is one copy.** The steps show this Mac's own command, for every client
  AGENTS.md knows, plus a prompt addressed to the assistant. All of it is readable on screen by a person
  or by an assistant using computer use.

Parts A and B fix what is broken (findings 2–5). Parts C and D are the new surface (findings 1 and 6).
They go in that order.

## A. The bridge's lifecycle (MCPCore `ResilientBridge`, `MCPStdioBridge`)

- **A1. The bridge watches its parent.**
  - It records `getppid()` at start. When the parent changes (reparented to launchd), the bridge
    exits: it logs one line, closes the app link, and exits 0.
  - Mechanism: a kqueue process-exit source on the parent if the sandbox allows it (S3), otherwise
    `getppid()` checked every 5 s.
- **A2. It waits quietly while Verbinal is away.**
  - It retries when the sidecar's folder changes (a vnode watch, S2), so Verbinal is found about a
    second after it opens.
  - It also retries on a timer, as a fallback: every 2 s for the first minute, then every 30 s.
- **A3. It tries few sockets and logs changes, not attempts.**
  - It tries the sidecar's socket, then at most the three newest others.
  - It logs "Verbinal unreachable since …" once and "attached" once, not one line per try.
- **A4. It closes on request.**
  - A new notification, `notifications/com.codebg.verbinal/relay/close` with `{reason}`, from the
    app.
  - The bridge answers every request it holds with the reason, then exits 0. The client sees its
    server end, and its tools go.
- **A5. A refused bridge stops the way a closed one does** (A4, D3): it answers "Verbinal did not
  approve this assistant", then exits.
- **A6. It says what it is.**
  - The relay introduction gains:
    - its own pid and start time;
    - its parent's pid, and the parent's name when the sandbox lets it read one (S1);
    - its Verbinal version and build, and its executable path.
  - The app keeps these for C. Assistants never receive another bridge's details.

## B. Socket hygiene (app side)

- **B1. Leftover sockets go when the server starts.** Every `mcp-*.sock` in the group container that
  nobody listens at (`SocketSidecar.isListening` is false) is removed. One that answers is another
  running Verbinal (a dev build beside the store build) and stays.
- **B2. Quitting stops the server.** At `applicationWillTerminate` the server stops: its socket goes,
  and the sidecar too if it is the app's own. Bridges see the link close and wait (A2).
- **B3. A Diagnostics row: leftover sockets.** It counts dead `mcp-*.sock` files, with **Remove**.

## C. Connected assistants: the monitor (new module `Verbinal/AssistantConnections/`)

A separate module with its own model, service, views and tools, as new features are (feedback: separate
modules).

- **C1. One row per connection, live.** Each row shows:
  - the client, as its `initialize` names it (`claude-code 2.1`, `codex …`);
  - the assistant's own words from `start_session`: agent, model, purpose;
  - the session: asking, allowed, ended (and why), or none yet;
  - the bridge: pid and start time, and its parent (name and pid);
  - "an older Verbinal (1.4.1)" when the bridge's version differs from the app's;
  - connected since, last call, number of calls, and how many proposals wait.
- **C2. Close and Close All.**
  - Close sends A4, ends the session (a new `Ending`: `closedByPerson`) and closes the socket.
  - The session log says who closed it and when. Any calls in flight are answered "closed by the
    person in Verbinal".
- **C3. Turning AI agents off closes every bridge (A4) before the listener stops** (D2).
- **C4. Where it lives** (D1): the recommendation is Settings ▸ AI Agent ▸ **Connected Assistants**,
  above Session Logs. The activity bar gains "2 assistants", whose popover lists them with Close.
- **C5. What deserves a look** is marked on the row:
  - a bridge from an older Verbinal;
  - a session that ended by idle, while the bridge stays connected;
  - a parent that is gone, if A1 has not ended the bridge yet.

  Nothing is closed without the person (D7).
- **C6. The session log records each connection's lifecycle.** Lines read: "connected: Claude Code 2.1,
  bridge 5206, launched by claude (5181)"; "closed by you"; "the client hung up"; "Verbinal quit; waiting".
- **C7. Assistants.**
  - An assistant reads only its own connection: `describe_app` → `connection` (since, bridge version,
    the session's idle end).
  - Listing or closing other connections is the person's own, as End Session is.
  - The parity doc gets rows "— the person's own" for C2 and C3, and a read row for C7.

## D. Connecting: recipes and the prompt

- **D1. One source of truth.** `AssistantRecipes` builds, per client, from this Mac's executable path
  (`resolveHelperPath`):
  - the config file;
  - the snippet, in that client's format;
  - the command, where the client has one.

  The clients:
  - Claude Desktop: one-click, as today;
  - Claude Code: `claude mcp add`;
  - Codex: `~/.codex/config.toml`;
  - Cursor, Gemini CLI, Windsurf: the `mcpServers` JSON;
  - VS Code: `servers` with `type: stdio`;
  - Other: name, command and arguments.
- **D2. The prompt for any assistant**, with **Copy**:

  > Connect yourself to Verbinal, the CADC/CANFAR app on this Mac. It is a local stdio MCP server: name
  > `verbinal-canfar`, command `/Applications/Verbinal.app/Contents/MacOS/Verbinal`, arguments `["mcp"]`;
  > no port, URL or key. Add it to your MCP configuration without removing the servers already there,
  > then reload so it appears. Call `describe_app`, then `start_session` saying who you are and why — I
  > approve the session in Verbinal. Exact settings for each client:
  > https://github.com/szautkin/canfar-macos/blob/main/AGENTS.md

  The path is this Mac's own. The identifiers never change; the prose follows D5.
- **D3. Where they show.**
  - The wizard's **Pick your client** step lists every client. Each shows its file, snippet and
    **Copy**, and Claude Desktop keeps **Configure**.
  - Settings ▸ MCP Clients shows the same list.
  - The empty Connected Assistants (C4) says "No assistant is connected" with the prompt under it.
- **D4. Readable by an assistant that looks at the screen.**
  - Each recipe and the prompt is whole, selectable text, never truncated. Each has an accessibility
    label and a pointable id (`assistants.prompt`, `assistants.recipe.codex`, …).
  - Checked with `list_ui_targets`.
- **D5. No drift.** A test builds the recipes for `/Applications/Verbinal.app` and checks that AGENTS.md
  shows the same snippets and the same prompt.

## E. Manual and AGENTS.md (English and French)

- **Chapter 12, Connecting an assistant:** every client, and the prompt.
- **Chapter 12, a new section, Connected assistants:** the list, Close, and what each mark means.
- **Chapter 12, Stopping an assistant:** Close, and what turning AI agents off now does (D2).
- **Chapter 16:** leftover sockets, and a log that grows.
- **AGENTS.md:**
  - the bridge ends with its client;
  - the person can close it, and the client then shows the server ended;
  - the prompt.
- **Coverage:** `scripts/manual-coverage.py` and `docs/manual/COVERAGE.md` gain the new section's row.

## Spikes first (each a throwaway, the answer written here)

The answers came from the sandboxed Debug build run as `Verbinal mcp-spike` under a shell that exited
after 1.5 s (2026-10-28):

- **S1: yes.** `proc_name`, `proc_pidpath` and `sysctl KERN_PROC_PID` all read the parent (`bash`,
  `/bin/bash`).
- **S2: yes.** An `O_EVTONLY` vnode source on the group container fires on a file written there.
- **S3: yes.** A `DispatchSource` process source on the parent fires at its exit, and `getppid()` is
  then 1.
- **S4: not run.** It would have to close the person's own Claude Code and Codex sessions. It is live
  case L2.

The questions:

- **S1. Can the sandboxed bridge read its parent's name?** Try `proc_name(getppid())` and
  `sysctl KERN_PROC_PID`. If not, the row shows the client's own `initialize` name and the parent pid
  only.
- **S2. Can the bridge watch the group container folder?** It reads files there already, but a
  `DispatchSource` vnode watch is a different permission.
- **S3. Can the bridge watch its parent's exit?** Try a `DispatchSource` process source on a non-child
  pid in the sandbox; the fallback is polling `getppid()`.
- **S4. What do Claude Code, Claude Desktop and Codex do when their server exits?** Each either marks it
  failed or relaunches it. A relaunch is a new bridge and a new `start_session`, which the person sees
  in C.

## Decisions for the person

- **D1. Where Connected Assistants lives.**
  - (a) Settings ▸ AI Agent, above Session Logs, plus a count on the activity bar. **Recommended.**
  - (b) Its own Home tile.
- **D2. What turning AI agents off does.**
  - (a) Close every bridge: nothing dangles, and turning on again needs each client to reload its
    server. **Recommended:** it is what "off" means to a person.
  - (b) Today: bridges wait and re-attach.
- **D3. A declined assistant's bridge.**
  - (a) Exit after answering "declined". **Recommended.**
  - (b) Stay, answering "the person declined this session".
- **D4. Quitting Verbinal.**
  - (a) Bridges wait quietly (A2), and sessions continue at the next launch (plan 34 S).
    **Recommended.**
  - (b) Close them all.
- **D5. The prompt's language.**
  - (a) The app's language, with identifiers unchanged; assistants read both. **Recommended.**
  - (b) English always, as AGENTS.md is.
- **D6. One-click Configure for Codex, Cursor, Gemini CLI and Windsurf.** These would use a folder grant,
  like Claude Desktop. **Recommended:** later (1.4.3); copying is enough for this fix.
- **D7. Close idle bridges on their own?** **Recommended:** no. An ended session already refuses calls,
  and a bridge whose client lives is that client's to keep; C5 marks it for the person instead.

## Steps (each one commit, tests failing first)

1. S1–S4 spikes; the answers written into this plan.
2. **B1, B2, B3:** prune, stop at quit, the Diagnostics row.
   - Tests: dead sockets go, a listening one stays; quitting removes the socket and the app's own
     sidecar.
3. **A2, A3:** waiting with backoff and a watch, logging changes only.
   - Tests: an injected clock and connect; a sidecar change attaches at once; one log line per state.
4. **A1, A4, A5:** parent watch, closing on request, declined words.
   - Tests: a parent change ends `run()`; close answers what was pending and ends `run()`; the
     declined text.
5. **A6, C1, C2, C6:** the introduction's details and the registry with Close.
   - Tests: connect, call, close; the session ends `closedByPerson`; the log lines.
6. **C3, C4, C5:** the Connected Assistants view and the activity-bar count (D1, D2).
   - Test: an on-screen test of the row and Close, by accessibility name.
7. **D1–D5:** the recipes, the prompt, the wizard and Settings.
   - Tests: each snippet parses (JSON, TOML) and quotes a path with spaces; AGENTS.md matches.
8. **C7 and parity:** `describe_app.connection`, and the parity doc rows.
9. **E:** manual (en/fr), AGENTS.md, coverage. Screenshots for chapter 12 when the UI is final.

## Where it stands (2026-10-28)

Steps 1–9 are built, uncommitted on `1_4_2` (the person commits).

- **Tests:**
  - The shared package passes.
  - The whole Mac suite ran: 2,395 tests, before the file splits below. Afterwards the 208 affected
    tests ran again and pass.
  - Two tests fail on this Mac, and fail the same way on the clean branch (checked with a stash):
    - `SidecarKeeperTests.testItLeavesTheSidecarOfAnotherVerbinalThatListens`: the sandboxed test host
      may not bind a socket in `/tmp`.
    - `EveryScreenNamedTests.testEverySettingsSectionHasNamesForEveryControl`: Settings ▸ AI Agent's
      hand tags are not found.
- **Seen on screen** in English and French, by a throwaway capture test:
  - Connected Assistants: empty, and with two rows;
  - Other Assistants;
  - the activity bar's count.
- **A1 live:** the Debug bridge, its shell parent gone, logged "stopping: The assistant's client has
  quit." and exited.

Beyond the plan:
- Diagnostics' **Restart** keeps sessions and relays. Before, it toggled the switch, which ended every
  session.
- The file budget (`CodeQualityGuardrailTests`) asked for splits, and the ceilings were lowered to
  match:
  - `AgentConnectionRoster`: the connections and closing;
  - `AgentsService+BackgroundApply`;
  - `AppState+AgentSessions`: the session wiring.
- `CHANGELOG.md` has an Unreleased entry.

From the person's first live look (2026-10-28): "maybe, we need to let users know to close the caller
ai app to completly close the bidge?" Codex's bridge was from 1.4.1. Close disconnected it, it came
back in 2 s with its session ended, and its row said "Close ends it", which was not true for it. Now:
- A bridge older than 1.4.2 has one mark: "which can't be closed from here: quit the assistant's app
  (codex-mcp-client) to end it".
- Its row loses **Close** once its session has ended.
- "Close ends it" shows only where Close does.
- The footer and the manual add: if an app starts its bridge again, quit that app, or remove Verbinal
  from its settings.

The person's Xcode build had rewritten `Localizable.xcstrings` again (see the xcstrings lesson). It was
rebuilt from HEAD plus this branch's 42 keys.

Left:
- The live cases below.
- Chapter 12's setup picture, which still shows two client cards.

## Live cases (after step 9)

- **L1.** Claude Code and Codex connected: both listed, each with its client, parent, session and last
  call.
- **L2.** Close one: its client shows the server ended. The other keeps working. The session log
  says "closed by you".
- **L3.** `kill -9` a client: its bridge is gone within 5 s, and its row with it.
- **L4.** Quit Verbinal for 10 minutes: each bridge logs a few lines, not thousands. Open Verbinal: both
  re-attach within about 2 s, with their sessions continuing.
- **L5.** Turn AI agents off (per D2), then on: what D2 says happens, happens.
- **L6.** Leftover sockets from a crash (kill -9 Verbinal): gone at the next launch. The Diagnostics row
  reads 0.
- **L7.** A fresh assistant, given only the copied prompt, connects itself.
- **L8.** An assistant using computer use reads the prompt from the screen in full.

## Out of scope

- One-click Configure beyond Claude Desktop (D6).
- Any network transport: the bridge stays local stdio only.
- Approvals in clients' own settings: plan 43, parked.
