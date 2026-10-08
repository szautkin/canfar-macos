# What the manual covers

This is a list for whoever maintains the manual; it is not part of the manual itself.
`scripts/manual-coverage.py` reads it in CI. Each table maps a part of the app, as the code names it,
to the chapter that covers it:

- **Item**: the app's own name for it.
- **Label**: the words the person sees, as `Localizable.xcstrings` has them. The chapter must use them
  in English in `en/`, and in French in `fr/`.
- **Heading**: an English heading of that chapter.

The check fails when an item of the app has no row here, or when a row points at a chapter or heading
that is not there. Every keyboard shortcut must also be in `a-shortcuts-and-menus.md`; the check reads
them from the code.

When the app gains a screen, a sheet, a setting, a menu item or a shortcut, add it here and to its
chapter, in both languages.

## Screens

| Item | Label | Chapter | Heading |
|---|---|---|---|
| `landing` | Landing | 01-getting-started.md | Home |
| `search` | Search | 02-search.md | |
| `research` | Research | 03-research.md | |
| `fitsViewer` | FITS Viewer | 04-fits-viewer.md | |
| `cubeViewer` | Cube Viewer | 05-cube-viewer.md | |
| `portal` | Portal | 06-portal-sessions.md | |
| `storage` | Storage | 09-storage.md | |
| `remoteCompute` | Remote Compute | 10-remote-compute.md | |
| `workflows` | Workflows | 11-workflows.md | |
| `aiGuide` | AI Guide | 13-ai-guide.md | |

## Sheets

| Item | Label | Chapter | Heading |
|---|---|---|---|
| `login` | Log In to CANFAR | 01-getting-started.md | Signing in and out |
| `about` | About Verbinal | 01-getting-started.md | Help, and what Verbinal can do |
| `export` | Export Data | 03-research.md | Exporting everything |
| `agentProposals` | Agent Proposals | 12-ai-assistant.md | Pending: changes waiting for you |
| `features` | What Verbinal Can Do | 01-getting-started.md | Help, and what Verbinal can do |
| `welcome` | Welcome to Verbinal | 01-getting-started.md | The first launch |
| `mcpSetupWizard` | Connect your AI agent | 12-ai-assistant.md | Connecting an assistant |

## Settings

| Item | Label | Chapter | Heading |
|---|---|---|---|
| `general` | General | 14-settings.md | General |
| `portal` | Portal | 14-settings.md | Portal |
| `agent` | AI Agent | 14-settings.md | AI Agent |
| `imageDiscovery` | Image Discovery | 14-settings.md | Image Discovery |
| `aiCompute` | AI Compute | 14-settings.md | AI Compute |
| `mcpClients` | MCP Clients | 14-settings.md | MCP Clients |
| `endpoints` | Endpoints | 14-settings.md | Endpoints |
| `about` | About | 14-settings.md | About |

## Menus

| Item | Label | Chapter | Heading |
|---|---|---|---|
| `Export All…` | Export All… | a-shortcuts-and-menus.md | File |
| `About Verbinal` | About Verbinal | a-shortcuts-and-menus.md | Verbinal |
| `Go` | Go | a-shortcuts-and-menus.md | Go |
| `Landing` | Landing | a-shortcuts-and-menus.md | Go |
| `Search` | Search | a-shortcuts-and-menus.md | Go |
| `Research` | Research | a-shortcuts-and-menus.md | Go |
| `FITS Viewer` | FITS Viewer | a-shortcuts-and-menus.md | Go |
| `Cube Viewer` | Cube Viewer | a-shortcuts-and-menus.md | Go |
| `Workflows` | Workflows | a-shortcuts-and-menus.md | Go |
| `Portal` | Portal | a-shortcuts-and-menus.md | Go |
| `Storage` | Storage | a-shortcuts-and-menus.md | Go |
| `AI Guide` | AI Guide | a-shortcuts-and-menus.md | Go |
| `Image Discovery…` | Image Discovery… | a-shortcuts-and-menus.md | Go |
| `Zoom In` | Zoom In | a-shortcuts-and-menus.md | View |
| `Zoom Out` | Zoom Out | a-shortcuts-and-menus.md | View |
| `Actual Size` | Actual Size | a-shortcuts-and-menus.md | View |
| `Zoom to Fit` | Zoom to Fit | a-shortcuts-and-menus.md | View |
| `What Verbinal Can Do…` | What Verbinal Can Do… | a-shortcuts-and-menus.md | Help |
| `Connect an AI Agent…` | Connect an AI Agent… | a-shortcuts-and-menus.md | Help |
| `Verbinal Help` | Verbinal Help | a-shortcuts-and-menus.md | Help |
| `Report an Issue` | Report an Issue | a-shortcuts-and-menus.md | Help |

## Interaction areas

Every area of [the parity matrix](../agent-ui-parity.md), which lists what a person can do on each
screen. Areas that are about assistants only point at the AI chapter.

| Item | Label | Chapter | Heading |
|---|---|---|---|
| `Finding your way (tool map)` | — | 12-ai-assistant.md | Hints: what your assistant shows you |
| `Long work` | — | 12-ai-assistant.md | Watching an assistant work |
| `Seeing the viewers` | — | 12-ai-assistant.md | What an assistant can and cannot do |
| `Search — form` | — | 02-search.md | The search form |
| `Search — ADQL editor` | — | 02-search.md | The ADQL editor |
| `Search — results table` | — | 02-search.md | The results |
| `Search — side panel` | — | 02-search.md | Recent searches and saved queries |
| `FITS viewer` | — | 04-fits-viewer.md | Marks |
| `Cube viewer` | — | 05-cube-viewer.md | Marks |
| `Portal / sessions` | — | 06-portal-sessions.md | Launching a session |
| `Image discovery` | — | 08-image-discovery.md | Finding the image that has your packages |
| `Remote Compute` | — | 10-remote-compute.md | Running code |
| `Storage (VOSpace)` | — | 09-storage.md | Files and folders |
| `Shell / navigation / settings` | — | 01-getting-started.md | The window |
| `Workflows` | — | 11-workflows.md | Following a workflow |
| `Assistant session (the approval window; Settings ▸ AI Agent ▸ Session Instructions)` | — | 12-ai-assistant.md | Allowing a session |
| `Session log (Settings ▸ AI Agent ▸ Session Logs)` | — | 12-ai-assistant.md | The session log |
| `Wire-name aliases (Windows = canonical)` | — | 12-ai-assistant.md | What an assistant can and cannot do |
| `Intentionally not exposed` | — | 12-ai-assistant.md | What an assistant can and cannot do |
