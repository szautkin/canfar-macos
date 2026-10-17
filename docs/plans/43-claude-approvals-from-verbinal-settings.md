# Plan 43 — The assistant app's approvals, from Verbinal's settings

**Date:** 2026-10-17 · **Branch:** `dev_1_4_1` (from `3e58d39a`, after plan 42) · **Release:** 1.4.1 (the
person: "we do it here, in 1_4_1")

The person, after the live check of plan 42, when Claude Code blocked the GPU launches that Verbinal allowed:

- "we need wizard default rules into settings both desktop and claude code"
- "next we need button switch for those permissions in settings propagated into claude settings"
- "plan this and add info for users, and inside the app how to explain users which button enable what
  permission"

**Decided (2026-10-17):** when a kind is **Ask me**, the assistant's app lets the call through and
Verbinal holds it in Pending. You are asked once, in Verbinal, with the assistant's reason.

## How it is now

**Two gatekeepers, one of them unmentioned.**

- **Verbinal.** Settings ▸ AI Agent has a switch per kind of change: **Allowed** applies at once,
  **Ask me** waits in Pending, and **What every assistant is told** always waits.
- **The assistant's app.** It decides, before Verbinal sees anything, whether the assistant may call a
  tool at all. Nothing in Verbinal (the wizard, Settings, the manual, AGENTS.md) says this gate
  exists.

**What happened on 2026-10-17.**

- Verbinal allowed launches: both allocation kinds were **Allowed**.
- Claude Code, in auto mode, blocked `launch_session` ("Real-World Transactions") and
  `launch_headless_job` ("Shared Cluster Mutation").
- The person's "I allow it" in the conversation was not a rule.
- Once, an 8-GPU `launch_session` went through. Auto mode judges each call on its own, so the
  outcome cannot be predicted.

**The wizard today.**

- **Claude Desktop.** After a folder grant (a security-scoped bookmark), Verbinal writes the
  `verbinal-canfar` entry into `claude_desktop_config.json`. It merges, and writes a `.bak` first.
- **Claude Code.** Verbinal never edits `~/.claude.json`, because it holds sign-in tokens. It gives
  the person the `claude mcp add` command to run.

## What the two apps offer (checked on this Mac, 2026-10-17)

**Claude Code 2.1.301.**

- **Where the rules live.** Permission rules are in `permissions.allow`, `ask` and `deny` of these
  files:
  - `~/.claude/settings.json` (the user's);
  - `.claude/settings.json` and `.claude/settings.local.json` (a project's);
  - managed settings.
- **The rule for Verbinal.** In an allow rule, a glob is accepted only in the tool position, after a
  literal `mcp__<server>__`. So **`mcp__verbinal-canfar__*`** covers every Verbinal tool, today's and
  any added later.
- **Precedence.** Deny wins over ask, which wins over allow.
- **Reloading.** Claude Code watches its settings folders, so a change should apply without a restart.
  Step 6 checks this.
- **Auto mode.** Auto mode honours an MCP allow rule. Claude Code's own refusal said so: "the user can
  add a permission rule for mcp__verbinal-canfar__launch_session". Step 6 checks this too.
- **Why Verbinal may write here.** `~/.claude/settings.json` holds no tokens, unlike `~/.claude.json`.
  Verbinal can merge into it as it does for Claude Desktop.

**Claude Desktop 2.42304.**

- **No place for tool permissions in its config.** `claude_desktop_config.json` has no field for a
  local (stdio) server's tool permissions.
- **Where the choices are kept instead.** Claude Desktop has four choices for each tool: **Always
  allow**, **Ask each time**, **Ask once per session** and **Blocked**. The app keeps them itself.
  Either the person sets them in Claude Desktop, or an organisation sets them through managed policy
  ("Tool policy").
- **The one related file is not usable.** `mcp-user-tool-toggles.json` holds only which tools are
  switched off, in an internal, versioned format.

**So:**

- **Claude Code:** Verbinal writes its rule.
- **Claude Desktop:** Verbinal says what to choose there, and cannot write it. The person asked for
  both apps; this is the limit for Desktop.

## The design: one gate, Verbinal

**Claude Code: one rule.** Verbinal writes `mcp__verbinal-canfar__*` to `~/.claude/settings.json`.
Claude Code then neither asks about nor blocks Verbinal's calls, and Verbinal's switches decide each
change as they do today.

**Why one rule, and not a rule per kind:**

1. **It is what was decided.** You are asked once, in Verbinal, where the change and its reason are
   shown.
2. **Claude Code cannot tell some kinds apart.** A tool's kind can depend on what it acts on.
   `delete_session` is **Remove what an assistant made** for an assistant's session, but **Stop
   running work** for yours. Claude Code's rules see only the tool's name.
3. **Tools added later are covered.**
4. **The switches act inside Verbinal**, the same way for every assistant's app. Nothing about them
   needs copying anywhere.

**What gets propagated.** The person asked for a switch that propagates. With the decision above, it
is one switch per app: **Claude Code ▸ Leave the asking to Verbinal**. On writes the rule; off removes
it. The kinds' switches stay where they are, and now say what each one lets an assistant do.

**The cost, said plainly in the app and the manual.** With the rule written, whatever is set to
**Allowed** happens with no question from either app. Verbinal's settings become the only check on its
tools.

## Steps

### Step 1 — Claude Code's settings: read, write, remove

A module of its own, following the rule that new features are separate modules:

- `Verbinal/Settings/ClientApprovals/Models/ClaudeCodeApprovals.swift`
- `Verbinal/Settings/ClientApprovals/Services/ClaudeCodeSettingsService.swift`

It reuses `MCPIntegrationSettingsService.realHomeDirectory`.

**The grant.**
- An Open panel, pre-targeted at the real `~/.claude`, with `showsHiddenFiles` on. Its message:
  "Select the “.claude” folder in your home folder, so Verbinal can add its rule to Claude Code's
  settings."
- It keeps a security-scoped bookmark under its own key.
- A folder that is not `~/.claude` is refused, saying so.
- Verbinal reads and writes only `settings.json` in that folder. A test holds the service to that one
  path.

**The status: read from the file every time, never stored.**
- `on`: the rule is in `permissions.allow`.
- `off`
- `unknown`: there is no grant yet, or the file cannot be read.

It also reports:
- **conflicts**: `ask` or `deny` rules that cover Verbinal's tools (`mcp__verbinal-canfar…`,
  `mcp__*`), because they win over the allow rule;
- **the person's own rules**: `mcp__verbinal-canfar__…` entries that the person added by hand.

**Writing.**
- It is a pure merge, `merged(existing:on:)`, the same shape as `mergedRoot`:
  - **on:** it ensures there is a `permissions` object with an `allow` array, and adds the rule if it
    is missing;
  - **off:** it removes exactly that string.
- Everything else is left alone: `ask`, `deny`, `defaultMode`, other keys, and the person's own
  Verbinal rules.
- **What it refuses**, with nothing written:
  - JSON that is not valid;
  - `permissions` or `allow` of the wrong type;
  - a `settings.json` that is a symbolic link. Writing over it would break a dotfiles setup, so the
    person copies the rule instead.
- **How it writes:** a `.bak` first, then a temporary file and `replaceItemAt`.
- **If Claude Code writes at the same moment** (`/permissions`): when the file changed after it was
  read, Verbinal reads it again and merges once more.
- **When the file is missing,** it is created with just the rule.

**Copy.** The rule itself, for the person to paste or add with `/permissions`.

**Tests**, fail-first:
- the merge: an empty file; one with other keys; adding twice changes nothing; off keeps the
  person's own rules; conflicts are found; bad JSON and wrong types are refused;
- the service, on a temporary folder: the `.bak`, the symbolic-link refusal, a change from outside
  between the read and the write.

### Step 2 — Settings ▸ AI Agent: who asks you

**A new section under the kinds: "Your assistant app's own approvals".**

- **Claude Code.**
  - A switch, **Leave the asking to Verbinal**, with its state read from the file.
  - Under it: "Claude Code calls Verbinal's tools without asking; Verbinal applies each change or holds
    it in Pending, as set above."
  - While there is no grant: **Grant Access…**, and the switch disabled with "Not known yet".
  - Conflicts, by name: "Claude Code still asks before delete_session: a rule in your settings
    says so." The same for blocks.
  - The person's own rules: "Also in your settings, added by you: …"
  - **Reveal** and **Copy Rule**.
- **Claude Desktop.** No switch. The text: "Claude Desktop keeps its own choice for each tool. Choose
  **Always allow** for Verbinal's tools there, and Verbinal asks you as set above." With **Open
  Claude**.
- **Other apps.** "Codex, Cursor and the others ask in their own way. AGENTS.md says how to let
  Verbinal's tools through."

**Settings ▸ MCP Clients ▸ Claude Code** gets one line saying whether the rule is on, and **Change in AI
Agent**.

**Pointable ids,** so an assistant can show where the switch is:
- `settings.agent.approvals.claudeCode`
- `settings.agent.approvals.grant`
- `settings.agent.approvals.claudeDesktop`

**Tests:**
- an AX layout test: the section, the switch's state against a file, conflicts listed;
- captures in light and dark, looked at.

### Step 3 — Each switch says what it lets an assistant do

**What an assistant may do without asking** gets a short explainer at its top:

> 1. Your assistant's app lets the call reach Verbinal: in Claude Code, **Leave the asking to
>    Verbinal**; in Claude Desktop, **Always allow**.
> 2. Verbinal applies it at once (**Allowed**) or holds it in Pending (**Ask me**), by its kind.
> 3. Reading, and showing you things on screen, never ask.

**Each kind's row gets "What this lets an assistant do",** a disclosure listing its actions in plain
words, such as:

- **Use your CANFAR allocation: sessions and compute:** Launch a session · Renew a session · Start
  Remote Compute · Run code in Remote Compute.
- **Remove what an assistant made:** lists the deletes, "when an assistant made what they remove".

**Where the words come from.**
- `ChangeCatalog.actionByTool` gives a localized phrase per tool.
- A guardrail test holds every tool in `kindByTool` to having one, so the list cannot drift from the
  catalogue.
- The tool names are shown small after each phrase, for anyone who reads the session log.

**Learn more** links to the manual's new section (step 5).

**Tests:**
- the guardrail;
- an AX test that every row has its disclosure, and that the allocation row lists
  `launch_session`'s phrase.

### Step 4 — The wizard: a Permissions step

A step between **Configure** and **Verify**. The steps become: Allow AI agents · Pick your client ·
Configure · **Permissions** · Verify.

**At the top:**
- Verbinal's switches in short: which kinds are **Allowed** and which **Ask me**;
- **Change in Settings ▸ AI Agent**, a link.

**Claude Code.** The recommended action is the default: **Let Claude Code leave the asking to
Verbinal**.
- It opens the grant, then writes the rule, as in step 1.
- **Not now** skips it.
- **Copy Rule** gives the `/permissions` way.
- The result is shown: on, or why not.

**Claude Desktop.** The step 2 text, with the one choice to make, **Always allow** for Verbinal's tools,
and **Open Claude**.

**Verify** adds a line: "Check: ask your assistant to call `describe_app`, then a tool that changes
something you allow."

**Tests:**
- the step's place for each client;
- its texts;
- the Claude Code button writes, through a service given a temporary folder.

### Step 5 — Told: the assistant, the manual, AGENTS.md

- **`describe_app`**, in "Write surface": "Your client's own approvals come first. When it blocks a
  Verbinal tool, tell the person: Settings ▸ AI Agent ▸ Your assistant app's own approvals." A test
  holds the brief to this text.
- **AGENTS.md**, in "Once you are connected":
  - the two gates;
  - the Claude Code rule, `mcp__verbinal-canfar__*`;
  - Claude Desktop's **Always allow**;
  - for other clients, to let Verbinal's tools through in their own approvals.
- **The manual, in English and French:**
  - **12-ai-assistant:** a new section, **Who asks you: Verbinal and your assistant's app**. It covers
    the two gates, a table of each switch and what it enables, the Claude Code switch with its cost,
    Claude Desktop's **Always allow**, and other apps. The setup's steps get **Permissions**.
  - **14-settings:** rows for the new section, and for MCP Clients' line.
  - **16-troubleshooting:** "Claude Code blocked a Verbinal tool" → the switch, or `/permissions`.
- **Pictures to take:**
  - `setup-wizard.png`;
  - `settings-agent-permissions.png`;
  - a new `settings-agent-approvals.png`.

### Step 6 — Seen working, and handout 37's section U

**Live, on a build from step 5:**

1. **Settings ▸ AI Agent.** Grant access to `~/.claude`, and turn **Leave the asking to Verbinal** on.
   `~/.claude/settings.json` has the rule, its `.bak` is beside it, and nothing else changed.
2. **The rule works in auto mode,** in this same Claude Code session, with no restart:
   - `launch_session` with 4 GPUs (O6, T7) passes;
   - so does the GPU batch job, `nvidia-smi` on `astroflow-cuda:25.03`, 1 CPU, 1 GB, 1 GPU.

   This finishes the GPU session and batch checks from 2026-10-17.
3. **Turning it off** removes only the rule. A rule the person added by hand stays, and is listed.
4. **An `ask` rule for `delete_session`** is listed as a conflict.

**Handout 37, section U:**
- the wizard on both apps;
- the switch on and off;
- a hand-added rule;
- a symbolic-link `settings.json`;
- an `ask` rule;
- auto mode;
- French.

## For the person

- **Claude Desktop.** Verbinal cannot write its tool permissions: there is no supported file for them.
  Verbinal says what to choose (**Always allow**) and opens Claude.
- **The grant.** It is the whole `~/.claude` folder, as Claude Desktop's grant is its whole folder.
  Verbinal reads and writes only `settings.json` there.
- **The default.** In the wizard, the rule is the recommended choice. It is written only when you
  press the button, because the folder grant needs your click anyway.
- **Labels to check:**
  - **Your assistant app's own approvals**
  - **Leave the asking to Verbinal**
  - **What this lets an assistant do**

## What it costs

- **Code:** about 400 lines (service, merge, two views, the wizard step, the action phrases), and about
  20 tests.
- **Words:** the manual in two languages; about 60 new strings in French.
- **The risk:**
  - Turning the switch on removes Claude Code's own check for Verbinal's tools. The person chooses it,
    and it is explained where it is turned on.
  - Writing someone's `settings.json` reformats it, as `/permissions` does. The `.bak` is kept.

## Not doing

- A Claude Code rule per kind: decided against (one gate).
- Writing Claude Desktop's internal files or managed policy.
- Codex, Cursor and the others: AGENTS.md only.
- A field in `get_current_view` saying whether the assistant's app will let calls through: Verbinal
  never sees the calls an app blocks.
