# Plan 23 — The assistant's session log: what happened, why, how long, whether it failed

**Date:** 2026-09-30
**Branch:** `release/1.4.0` (after `e268620`, the timeouts named once)
**Asked for** (the person, 2026-09-30):

- "help the assistant judge what's happening: tools to understand the time spent, and whether it is
  a failure"
- "the app should have its internal log of events that the AI agent can check"
- "not for the whole app all the time, but for the session started with the AI agent"
- "we can count it as a new session, we need to store it anyway, plan management of the logs to
  delete, or export them for user/debugging purpose as well"
- "important events like creating, downloading, making, deleting … and why"
- "logs should give 100% info for an agent to figure out what's happening or happened, give users
  100% info why, and help in debugging; DRY, Orthogonality, SOLID and ETC is a must"

## Status

| Step | State | Commit |
|---|---|---|
| P plan | done — every decision taken (below) | |
| L1 request ledger | done — every request recorded; one classification; the source guardrail | `a1255a2` |
| K cause: who and why travel with the work | done — `Cause`; `why` on every write, shown in Pending | `619e76f` |
| C every change recorded by its owner | done — the apply path for every assistant change; the owners below for the person's and the app's | `7e53441` |
| A the app's decisions say their rule | done — auto-apply, retries, deadlines (with what was waiting), the sign-in; expiry from the event log | `26fd739` |
| L2 session journal, stored | done — `AppEventHub`, `SessionJournal`, `SessionLogStore`, `SessionLogLine`; a session per connection | (this commit) |
| L3 reading the log: `get_session_log`, `explain_log_entry`, `list_session_logs` | not started | |
| L4 managing the logs: view, export, delete, retention | not started | |
| L5 timing on every reply | not started | |
| L6 activity and health read the ledger | not started | |
| L7 tool deadlines follow the timeouts | not started | |
| L8 words for the assistant, handout | not started | |

## Do we have it?

In pieces. None of them is scoped to the assistant's session, none is kept past a quit, none
records time spent waiting on CADC, none says why, and a failure is one line of text.

| What exists | What it holds | Can the assistant read it? | Scope |
|---|---|---|---|
| `list_events` | Proposals only: arrived, applied (and by whom), rejected, withdrawn, failed, expired | yes | the whole app, every agent, last 500, in memory |
| `list_activity` | The activity bar: launches, probes, transfers, downloads; who started each, its stage, seconds, a failure's reason | yes | the whole app, last 60, in memory |
| Tool-call audit (`AuditEntry`) | Every call: tool, outcome, duration in ms | **no**: it goes to `os_log` and the person's feed in Settings ▸ AI Agent | the whole app |
| Settings ▸ AI Agent ▸ Diagnostics | Whether the server is listening, what it last did | **no**: it is for the person | the server |
| Network requests | **nothing records them**: which endpoint, how long, how it ended | — | — |
| Changes the person makes without a task (a folder, a saved query, a Research record, a mark) | **nothing records them** | — | — |

What the assistant sees today when something goes wrong:

- **A tool deadline:** `backendError: search_observations exceeded 120s deadline — the upstream
  service may still be processing`. Nothing says which service it was waiting on, for how long, or
  whether retrying could help.
- **The wrong deadline, most of the time.** Read tools stop at 60 s by default (30 s for sessions,
  VOSpace listing, batch jobs, session images). Since `e268620`, the requests inside them wait up to
  120 s. The tool gives up while CADC is still within its time.
- **A failed request:** whatever `URLError` or HTTP status text reached the tool. "The request timed
  out." does not say who, and a timeout, a refusal and no network look alike.

## What the log guarantees

**One log per assistant session, stored on this Mac.** It opens when an assistant connects and
closes when it leaves. It covers everything that happens in the app in between, whoever does it.

1. **For the assistant, 100% of what happened.**
   - Every tool call.
   - Every change, by anyone.
   - Every task, every proposal's state, and every request to CADC or CANFAR.
   - Every decision the app took about the work.
   - Every failure, with its reason.

   The ids link cause to effect: this call → this proposal → applied by the person → this task →
   these requests → failed, because …. An assistant can work out what happened without asking the
   person.
2. **For the person, 100% of why.**
   - Every change says who made it and why: the assistant's own reason, "by you", or the app's
     rule.
   - Every decision the app took says its rule: "applied at once: auto-apply is on and this is not
     a delete"; "waiting in Pending: deletes always wait for you"; "not asked again: a search that
     timed out is not repeated".
   - Every failure says why, in words.
3. **For debugging, enough to reproduce.**
   - The session's header: the app's version and `buildCommit`, the macOS version, the endpoints in
     use and whether any is overridden, auto-apply, and sign-in state.
   - On every failure: its codes (HTTP status, `URLError` code, the failure's tag).
   - On every entry: its ids and timings.
4. **Never raw data or credentials** (decision 6).
   - The log keeps **meaning**: sentences, names, outcomes, codes, ids and times.
   - It never keeps tool arguments, or a request's method, path, query, headers or body. The URL is
     read once, to name the service.
   - The login's password, the bearer token, a registry secret and the ADQL therefore cannot reach
     it.

### How the 100% is kept: one recording point per kind of event, and a test that fails on a gap

| Event | Its one recording point | Guardrail |
|---|---|---|
| A tool call | `AIToolRouter.dispatch`: every call passes through it | the bridge's test: each call is in the session's journal |
| **A change** (created, launched, downloaded, uploaded, made, deleted, renewed, stopped, saved, exported, moved, changed) | **The owner that makes it** (`SessionActions`, `HeadlessLaunches`, `StorageService`, `DownloadService`, the Research store, …) records it through `ChangeLog`. The person's click and the assistant's applied proposal call the same owner, so one record covers both (DRY). | `ChangeCatalog` has one entry per write tool's kind (verb, and what it acts on). A test fails when a write tool is added without one, and when a catalogued change has no owner test. |
| A task | `TaskRegistry` | `TaskKind` is exhaustive in the journal's switch (the compiler) |
| A proposal's state | `ProposalStore` and `EventLog` | `AgentEvent` is exhaustive (the compiler) |
| A request | `RequestLedger`, at the few places requests are sent | **a source test**: no `URLSession` send (`data(for:)`, `download(for:)`, `upload(for:…)`, `downloadTask`) outside the recorded places |
| A decision the app takes | the policy that takes it: `AutoApplyPolicy`, proposal expiry, `RetryPolicy`, the tool and applier deadlines, the dispatch ceiling, the session limit | one test per policy: its decision is recorded with its rule |
| A failure's reason | `RequestOutcome`, `ToolFailureReason`, a task's message | exhaustive switches (the compiler) |
| Sign-in, other assistants | `AuthLifecycleController`, `AgentsService` | a test per event |

### The principles, where each one shows

| Principle | Where |
|---|---|
| **DRY** | One classification of how a request ended (`RequestOutcome`), which `SearchError.describing` and the health probes use instead of their own. One naming of services (`RequestService`). One `ChangeCatalog` of verbs. One cause (`Cause`), read where things are recorded and never passed by hand. One line formatter (`SessionLogLine`) for the view, the text export and the tool's `line`. Every timeout from `RequestTimeout`. |
| **Orthogonality** | The ledger knows nothing of sessions or tools. Tasks, proposals and owners know nothing of the journal. They each offer an observer or record to one small interface, and only `AppEventHub` connects them to journals. Removing the AgentSession module changes no behaviour. |
| **SOLID** | Single responsibility: the ledger records, `RequestOutcome` classifies, the journal orders, the store keeps files, retention prunes, export writes, the formatter words. Open–closed: a new write tool gets `why` and logging without an edit; a new send place needs only the wrapper; a new source only subscribes. Liskov and interface segregation: small protocols (`AgentSessionRecorder`: opened, call, closed; `ChangeRecording`: record), each with a test double. Dependency inversion: VerbinalKit declares the protocols; the app implements them. |
| **ETC** | Entries carry a schema version in the session header, and a reader skips kinds it does not know. The verb table and the service names are data, not branches. New entry kinds are added, never reshaped. |

## The pieces, and who owns what

| Piece | Where | Owns |
|---|---|---|
| `RequestOutcome` | VerbinalKit/Networking | How a request ended, its meaning and its retry advice (table below) |
| `RequestService` | VerbinalKit/Networking | A request's service, named from its URL. Its id matches `get_service_health`'s names (`cadc-tap`, `cadc-registry`, …); its name is in words ("the CADC archive search"). |
| `RequestLedger` | VerbinalKit/Networking | Every request: service, start, its timeout, seconds, outcome, status or error code, and cause. In flight, plus the last 300 finished, in memory, with each service's recent calls and failures; it says when a service starts failing (three failures in a row) and recovers. Recorded by a wrapper that cannot leave a request unfinished (the `TaskHandle` rule). |
| `RequestTrace` | VerbinalKit/Networking | A task-local collector with a parent. A tool call and a tracked task each open one, and a request is added to every trace above it. |
| `Cause` | VerbinalKit/Agents | Task-local, beside `Initiator`: why, and the links (session, call, proposal, task). Set once where work enters: the router, a proposal's apply, an app rule. |
| `ChangeLog` / `ChangeCatalog` | VerbinalKit/Agents (protocol), app (catalogue) | A change's record (`verb`, what it acts on, outcome, seconds; who and why from `Cause`); the catalogue of change kinds |
| `CallTiming` | VerbinalKit/Agents | A call's seconds, its requests, and a verdict: what happened in one sentence, plus `retry` |
| `AgentSessionRecorder` | VerbinalKit/Agents | What the bridge reports: a session opened, a call ended, the session closed. The bridge is one per connection, so one per session. |
| `AgentSession` | new module `Verbinal/AgentSession/` (Models, Services, MCP, Views); macOS only, like the MCP server | `SessionJournal`, `AppEventHub`, `SessionLogStore`, `SessionLogQuery`, `SessionLogRetention`, `SessionLogExport`, `SessionLogLine`: one job each |

**How a request ended** (`RequestOutcome`). A request that got an answer is `ok` (2xx or 3xx). The
failures:

| Outcome | Cause | Meaning | Retry |
|---|---|---|---|
| `timedOut` | no reply within its timeout | the service is slow or down | `later` |
| `unreachable` | DNS, connect, TLS, or connection lost | the service or the route to it is down | `later` |
| `offline` | this Mac has no network | — | `later` |
| `busy` | 429 or 503 | — | `later` |
| `serverError` | 5xx | the service failed | `later` |
| `signInNeeded` | 401 | the person must sign in | `afterSignIn` |
| `notAllowed` | 403 | — | `no` |
| `notFound` | 404 | — | `no` |
| `rejected` | other 4xx | the request was wrong | `no` |
| `cancelled` | the app stopped waiting: a tool deadline, the person, or a quit | its cause says which | `now` |

**Where requests are recorded** (every place a request is sent, pinned by the source test):

- `NetworkClient.execute`, `putFileOnce`, `downloadFileOnce`
- `RegistryClient.fetch`
- `TAPClient`: queries, the resolver, DataLink
- `CAOM2Service`, `CutoutService`, `ResultExportService`
- the image registry (`RegistrySearch`, the Harbor ping and token)
- the health probes

## An entry

Every entry has the same frame, and a kind adds its own fields (ETC):

| Field | What it holds |
|---|---|
| `token` | The entry's place in the session. The assistant reads what is new with `since`. |
| `at` | when it happened |
| `kind` | `opened`, `action`, `call`, `task`, `proposal`, `decision`, `request`, `app` or `closed` |
| `line` | **One sentence**, the same the person's view shows and the text export writes. Example: "14:02 Deleted session qa-person (q9p87ajc) — by you, applying this assistant's proposal, because: throwaway from the QA pass. Done in 2 s." |
| `who` | `assistant` (this session's), `anotherAssistant` (with its `client`), `person` or `app`. The lines say "by the assistant", "by the person", "by Verbinal": both the person and the assistant read them. |
| `why` | the assistant's reason, "by you", or the app's rule |
| `outcome` | done, failed, waiting, … |
| `seconds` | how long it took |
| `ids` | session, call token, proposal, task, request |
| `codes` | on a failure: HTTP status, `URLError` code, the failure's tag |

| Kind | What it says |
|---|---|
| `opened` / `closed` | the header (debugging, above); how it ended: disconnected, or Verbinal quit |
| **`action`** | a change (the verbs above): what it acted on, who, why, how it ended, how long. From `ChangeLog`. If a task tracked it, the action carries the task's id and time, and that task shows no second entry. |
| `call` | this session's tool call: the tool, what came of it (answered, proposed, applied, still applying, or failed and why), seconds, and its requests nested (service, seconds, meaning) |
| `task` | work that is not a change: an image probe, the Research check. Its stages, and how it ended. |
| `proposal` | from anyone: waiting (and why it waits), rejected, withdrawn, expired. An applied or failed proposal is an action. |
| `decision` | a rule the app applied: auto-applied or held, retried or not, a deadline reached, a limit reached, a request not sent because sign-in is needed |
| `request` | a request **outside** this session's calls that failed, from anyone. A service starting to fail or recovering is an `app` entry. |
| `app` | signed in, signed out, sign-in expired; a service failing or recovering; another assistant connecting or leaving |

## The steps

### L1 — The request ledger

`RequestOutcome`, `RequestService`, `RequestLedger` and `RequestTrace`, wired in at every send
place.

Tests:

- the classification table
- service naming from each endpoint in use
- a request recorded as `ok`, `timedOut`, `cancelled` and `signInNeeded`
- traces nest, and a request reaches every trace above it
- nothing of a login's form reaches the ledger
- **the source test**: no send outside the recorded places

### K — Cause: who and why travel with the work

**`Cause`, a task-local beside `Initiator`,** is set once where work enters:

| Where work enters | Who | Why |
|---|---|---|
| the router, for a call | this session | from the call's `why` |
| a proposal's apply | whoever applies it | the proposal's `why`; the proposal's id is kept |
| an app rule | the app | the rule's words, via `TaskRegistry.begin(…, why:)` |
| the person, by default | the person | — |

Whatever is recorded reads it, so no call site passes why by hand, and none can forget it.

**Every write tool takes an optional `why`**, the assistant's reason in one sentence (200
characters at most):

- **Added once, for all write tools,** when the manifest is published. The router takes `why` off
  before the tool checks its arguments, so no tool changes (open–closed).
- **Kept on the proposal** (`PendingProposal.why`, stored).
- **Shown under the proposal in Pending,** so the person reads it before applying a delete.
- **Left out:** the action says "no reason given". The server's instructions ask for one on every
  write, above all a delete.

Tests:

- `why` is in every write tool's published schema, and in no read tool's
- the router strips it before the tool's own check
- it is kept on the proposal across a relaunch, and clipped when too long
- `Cause` reaches work started in child tasks, and a detached task takes it explicitly (as
  `Initiator` does, plan 19 T2)

### C — Every change recorded by its owner

1. **Inventory.** The parity matrix lists every change a person can make. The inventory maps each
   one to the owner that performs it, and each write tool's kind to a `ChangeCatalog` entry.
2. **Instrument each owner.** It records through `ChangeLog` (verb, what, outcome, seconds), and
   `Cause` supplies who and why. Where a task already tracks the change, the action takes the
   task's id, and the task shows no second entry.

Tests:

- the catalogue guardrail (every write kind is catalogued)
- one test per owner family (sessions, batch jobs, storage, downloads, Research, saved queries,
  marks, workflows, settings), each checking that the change is recorded with who and why, for both
  the person and an applied proposal

**The inventory, as built.** Every assistant change is recorded where it is applied
(`AgentsService`, one path). The person's and the app's are recorded where they are made:

| Owner | Changes |
|---|---|
| `SessionService` | launch, renew and delete a session: the launch form, a relaunch, the Portal, compute |
| `HeadlessService` | launch and delete a batch job: the form, the image probes |
| `VOSpaceBrowserService` | download, upload, make a folder, sharing, delete (folders with what they hold) |
| `DownloadService` | an observation, one of its files, a cutout cut by CADC |
| `LocalCutoutMaker` | a cutout cut on this Mac |
| `ObservationStore` | save to Research, delete a record, remove its file, clear Research, correct a publisher ID |
| `ObservationNoteStore` | a note saved or deleted |
| `SavedQueryStore`, `RecentSearchStore` | saved queries (save, update, rename, delete, clear); recent searches (rename, remove, clear) |
| `MarkStore`, `BookmarkStore`, `UserImageStore` | marks, sky bookmarks, the launch list's images |
| `FigureFile`, `MarkExportPanel`, `ExportService`, the results' Save panel | figures, marks, the Research bundle, search results |
| `RemoteComputeService` | code sent to run (its session, above) |
| `ImageDiscoveryCoordinator` | an image inspected; its cache and failures cleared |
| `WorkflowStore`, `AIGuideService` | workflows (save, use, step, update, delete); what assistants are told |
| `AgentsService`, the AI Compute, Image Discovery and Endpoints settings | allow agents, auto-apply, follow activity; images, cores, RAM, hosts; a secret saved or removed, never its value |

`WorkContext` carries who and why into the two detached tasks that make changes: the image probe
and the bundle upload that outlives its apply.

### A — The app's decisions say their rule

Each policy records a `decision` entry with its rule, in words:

| Policy | Its decisions |
|---|---|
| auto-apply | applied at once, or held for the person, and why |
| proposal expiry | expired unapplied after 3 hours |
| `RetryPolicy` | retried after a 503, with the wait; not retried after a timeout |
| the tool and applier deadlines, and the dispatch ceiling | stopped waiting, and what was still in flight |
| the session limit | a launch refused at 3 of 3 |
| sign-in | a request not sent because sign-in is needed |

Tests: one per policy.

**As built.** `DecisionLog` records a `Decision` (its rule and a sentence). The rules:

- **Auto-apply** (`AIToolRouter`): applied at once, or held, worded by `AutoApplyPolicy.rule`.
- **Retries** (`retrying`): asked again with the wait; or not, because of a timeout, the attempts, or
  the time allowed.
- **Deadlines** (`withToolTimeout`, `withApplierTimeout`, the dispatch ceiling): what was still
  waiting, from the call's trace, or that nothing was. The error the assistant gets says the same.
- **The sign-in** (`AuthLifecycleController`): renewed with the stored password, kept unchecked while
  CADC cannot be reached, or ended, and why.
- **Proposal expiry:** its one recording point stays the event log, and the journal words its rule.
- **The session limit:** not a decision the app takes. The app does not refuse an assistant's launch
  at 3 of 3; CANFAR does, and that failure is recorded with its reason. The form's disabled button
  refuses nothing.

One `Observers` type serves the ledger, the change log and the decision log (DRY).

### L2 — The session journal, stored

**What a session is** (decision 1): one connection from an assistant.

- **Verbinal restarts under an assistant:** the relay's reconnect opens a **new session**. The
  previous one is closed as "Verbinal quit" and kept, so the assistant can still read it (L3).
- **The id** is made when the session opens. The MCP `clientID` (`name/version`) cannot be the key,
  because two Claude Code windows share it; it is kept as the session's `client`.
- **What it records:** `AppEventHub` delivers each event to every open journal, and the journal
  marks this session's own work as `you`.

**Stored always** (decision 2): one JSON Lines file per session,
`Application Support/Verbinal/AgentSessions/<start>-<id>.jsonl`.

- The first line is the header.
- Each entry is appended as it happens.
- A session left open by a crash is closed at the next launch as "Verbinal quit".

**Size:** at most 2 MB per session, which fits the 10 MB rule. Past that, the oldest calls,
requests and app entries go first; actions and decisions go last. The file says what was dropped.

Tests:

- entries in order, tokens, and ids linking a call to its proposal, action and requests
- a relaunch closes an open file as "Verbinal quit"
- two connections from the same client get two sessions
- the size limit drops what it says it drops, actions last
- an action's who and why, for a proposal applied by the person, by auto-apply, and in the
  background; and for a change by the person and by the app
- nothing of a login's form reaches the file

**As built.** The MCP bridge reports to `AgentSessionRecorder` (opened, a call began and ended,
closed). `AppEventHub` hears the ledger, the change and decision logs, the event log, the activity
bar and the sign-in through each one's `Observers`, and takes their events in order off one stream.
`SessionLogLine` puts every entry into words, the one place. `CallTiming` (a call's requests and
verdict) moved up from L5, so the call's entry and its reply say the same. A request that fails
inside a call under way is told by the call; one that fails outside a call is its own entry.
Arrived, applied and failed proposal events are left to the decision and the action that tell them
already.

### L3 — Reading the log: three MCP tools

All three are reads, so no proposal is needed; any assistant can read any session's log.

| Question the assistant has | Tool |
|---|---|
| What is happening right now, and what has happened? | `get_session_log` |
| Why did this one thing happen, and what came of it? | `explain_log_entry` |
| What happened before Verbinal restarted, or in another session? | `list_session_logs`, then `get_session_log` with `session` |

**`get_session_log`** (read) — the session's log, and its present.

*Arguments* (all optional):

| Argument | What it does |
|---|---|
| `session` | which session to read; default: this one |
| `since` | a token: only entries after it, for polling |
| `only` | `actions`, `failures`, `decisions`, `calls`, `tasks`, `proposals`, `requests` or `app` |
| `who` | `you`, `person`, `app` or `anotherAssistant` |
| `about` | everything about one thing: a proposal, task or session id, a file or folder name, a service id (`cadc-tap`) |
| `text` | words in the lines |
| `from`, `to` | a time range |
| `limit` | default 50, at most 500 |

*Output:*

- `session`: the header (app version, `buildCommit`, macOS version, endpoints, auto-apply,
  sign-in), plus seconds open and how it ended
- `now` (this session only):
  - requests in flight: service, seconds, of its timeout
  - tasks running: stage, and what each is waiting on
  - proposals waiting, and why each waits
  - services failing now
  - sign-in state
- `summary`:
  - actions: done and failed, by who
  - calls: made, and how many failed
  - seconds spent waiting on each service, and the slowest request
  - decisions, by rule
- `entries`, newest last, each with its `line`; and `nextToken`
- `expired`: the token was older than what the file still holds

**`explain_log_entry`** (read) — one entry, and its chain of cause and effect.

- **Arguments:** `token`, and optionally `session`.
- **Output:** the entry, whole, with all its ids and codes, and:
  - `causes`: what led to it. The call that proposed it, the proposal and its `why`, who applied
    it, the rule behind a decision.
  - `effects`: what it led to. The task, its requests with their outcomes, the decisions taken,
    the action and how it ended.
  - `story`: the chain in plain sentences. Example: "You called delete_session at 14:01 because:
    throwaway from the QA pass → proposal 3F2A… waited in Pending (deletes always wait for the
    person) → the person applied it at 14:02 → skaha answered 200 in 1.8 s → session qa-person
    deleted."

The reply's timing note (L5) and a failure's message carry the entry's `token`, so the assistant can
go straight from a failed call to its explanation.

**`list_session_logs`** (read). Sessions, newest first, each with:

- id and client
- opened, closed, seconds
- how it ended
- actions, calls and failures
- whether it is **this** session

It also states the retention rule (10 days, 10 MB), and it is how an assistant finds its session
from before a restart.

**The tools already there:**

- `list_events` stays as it is (proposals, app-wide). Within a session, `get_session_log` with
  `only: proposals` gives the same events with who and why.
- `list_activity` stays too, and gains `waitingOn` (L6).
- Their descriptions point to the session log.

**One reader behind the three tools and the person's view** (DRY): `SessionLogQuery`. It filters,
links causes to effects and summarises, over `SessionLogStore` for closed sessions and the open
journal for this one.

Tests:

- this session and a closed one
- `since`, each `only`, `who`, `about`, `text` and the range
- `now` against a request in flight and a task running
- the summary's counts
- `explain_log_entry` for:
  - a failed call: its request, its outcome and the retry advice
  - an applied delete: the call, the why, who applied it, the request and the action
  - a held proposal: the auto-apply rule
- an expired token

### L4 — Managing the logs: view, export, delete, retention

**For the person: Settings ▸ AI Agent ▸ Session Logs.**

- **The list:** one row per session, with client, when, how long, actions, failures, and a mark on
  the open one.
- **A session's view:** its lines in time order. Actions, decisions and failures stand out, and a
  filter shows actions only. A call opens to show its requests; an entry opens to show its ids and
  codes.
- **Export** writes to where the person picks (a save panel):
  - **Text**: the lines, to read or attach to a report
  - **JSON Lines**: the entries, for tools
  - one session, several, or all, into one file, each session headed by its header
- **Delete**:
  - one session, several, or all closed ones
  - confirmed, because it cannot be undone
  - the open session is never deleted
- **Retention** (decision 7): 10 days, and 10 MB in all. The rule is fixed, with no setting. It runs
  at launch and when a session closes; the oldest closed logs go first, never the open one.
- **Show in Finder** for the folder.

**For the assistant (agent↔UI parity):**

| Tool | Kind | What it does |
|---|---|---|
| `export_session_log` | a write, applied at once with auto-apply on | writes one or more sessions to `~/Downloads/Verbinal session log ….txt` (or `.jsonl`) and answers with the path |
| `delete_session_logs` | **destructive** | waits in Pending for the person; never the open session |

**One owner each, called by both the view and the tools:**

| Owner | Job |
|---|---|
| `SessionLogStore` | reads, lists and deletes the files |
| `SessionLogQuery` | filters, links causes to effects, summarises (the same reader as L3's tools) |
| `SessionLogRetention` | decides what the rule removes |
| `SessionLogExport` | writes an export |
| `SessionLogLine` | words each entry |

Tests:

- retention by age and by size, oldest first, never the open session
- export of one and of several, as text and as JSON Lines; the text matches the view's lines
- a delete proposal waits in Pending
- the view's list matches `list_session_logs`

### L5 — Timing on every reply

**When the note appears:** only if the call touched the network, took 2 s or more, or failed. Quick
local reads are unchanged.

**What it looks like:** a second text block, `{"timing": {...}}`, with:

- `seconds`
- `requests`: service, seconds, timeout, outcome and meaning
- `verdict` and `retry`
- the call's token in the session log

Examples of the verdict:

- "the CADC archive search answered in 48 s: slow, but it answered."
- "the CADC archive search did not answer within its 120 s timeout. It is slow or down;
  `get_service_health` says which. Retry later."

The payload's own block stays byte for byte as it is.

**A deadline's message** names what was still in flight: "search_observations stopped waiting after
130 s; the CADC archive search had not answered in its 120 s. CADC is slow or down: retry later, or
read `get_session_log`." The same applies to `withApplierTimeout` and the dispatch ceiling.

Tests: the note's presence rules; a verdict for each outcome; a deadline naming its in-flight
request; the payload block unchanged.

### L6 — Activity and health read the ledger

- **`list_activity`:** a running task gets `waitingOn` (service, seconds, of its timeout); a finished
  task gets `requests` (count, failed, seconds on the network).
- **`get_service_health`:** keeps its live probe and adds `seenByApp`, what the app's own traffic
  showed in the last 15 minutes: calls, failures, median seconds, the last failure and when.

### L7 — Tool deadlines follow the timeouts

**Change** (decision 3): every read tool's deadline becomes `RequestTimeout.standard` + 10 s,
including the 30 s list tools (sessions, VOSpace listing, batch jobs, session images,
`read_vospace_file`).

- The 10 s let the request's own timeout fire first, since that is the one that names who did not
  answer.
- The router's read ceiling (150 s) stays above it.
- The 30 s dates from calls with no deadline at all, which hung for 5 minutes; the timing note now
  says what is slow.

**Unchanged:**

- `get_data_links`: 30 s, with its CAOM-2 fallback
- `get_preview_image`: 30 s
- `get_service_health`: 30 s; its probes take 15 s

### L8 — Words for the assistant, and the handout

- **Instructions:** `describe_app`, the server's instructions and `AGENTS.md`:
  - when something is slow or failed, read the reply's `timing`, then `explain_log_entry` with its
    token, then `get_session_log` (`now` says what is happening), then `get_service_health`
  - `retry: no` means change the request, not repeat it
  - after a restart, `list_session_logs` finds the previous session
  - give every write a `why`, above all a delete
- **Registration:** the new tools get `AIGuideCatalog` categories and rows in
  `docs/agent-ui-parity.md`.
- **Changelog** entries.
- **Handout 24** for QA:
  - a slow search (timing and verdict)
  - a forced deadline
  - a request while signed out
  - Verbinal quit and relaunched mid-session: a new session, with the old one readable and closed as
    "Verbinal quit"
  - two assistant windows: separate logs
  - a delete proposed with a `why`: the why shows in Pending, and the action in the log names who
    applied it and why
  - the person deletes a session from its Portal card: the action is "by you"
  - the person makes a folder and saves a query: both are actions
  - export one session and all of them, as text and as JSON Lines
  - delete through Pending
  - retention

## Out of scope

- **MCP progress notifications** (`notifications/progress`). Claude Code shows them to the person,
  not to the model.
- **A log outside assistant sessions.** `list_activity` and the ledger's recent requests cover the
  app between sessions, in memory.
- **iOS.** It has no MCP server. `RequestOutcome` and the ledger are in VerbinalKit and build there,
  unused for now.

## Decisions

All taken by the person, 2026-09-30:

1. **What a session is:** one connection. A Verbinal restart starts a new session, and the old one
   stays readable.
2. **Stored on disk:** always, one file per session.
3. **The 30 s list tools** follow the request timeouts, as every read tool does (L7).
4. **App events:** not only the assistant's own. Everything that happens in the app during the
   session is logged, whoever does it.
5. **The person manages the logs:** view, export and delete (L4).
6. **Meaning, not raw data:** no arguments, paths, methods, queries, headers or bodies, and no
   credentials. Each entry says in words what happened, **why**, and how it ended, with the ids,
   codes and times that debugging needs.
7. **Retention:** 10 days, and 10 MB in all.
8. **100%:** the log gives the assistant everything that happened, gives the person every why, and
   helps debugging. Each kind of event has one recording point, and a test fails on a gap. DRY,
   orthogonality, SOLID and ETC are required, as the principles table shows.
