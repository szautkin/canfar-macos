// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit
import MCPCore

/// Returns a single prose blob orienting an agent to Verbinal's surface:
/// what the app does, what tools are available, what the proposal model
/// is, what's *not* on the menu.
///
/// The brief is static, embedded in source. Single source of truth — when
/// new tools land, edit the brief and the schema together.
struct DescribeAppTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        /// An area id from `list_apps`; nil for the whole-app brief.
        var app: String?
    }

    struct Output: Encodable, Sendable {
        /// The person's guide tools, before anything else about the app.
        var standingRules: [AIGuideSnapshot.StandingRule]? = nil
        let brief: String?
        let serverVersion: String
        /// The commit the build was made from ("+" when it had uncommitted
        /// changes), so a pass can say which build it tested.
        var buildCommit: String? = Bundle.main.infoDictionary?["VerbinalBuildCommit"] as? String
        let app: ToolMap.Area?
        let tools: [ToolMap.Entry]?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "describe_app",
        description: "Get a prose overview of Verbinal's capabilities, tool surface, and proposal model — call this once at the start of a session; `serverVersion` and `buildCommit` say which build answers. It opens with the person's standing rules (`standingRules`: their own guide tools; call each for its whole text and follow it). With `app` (an area id from list_apps), get that area's tools with a one-line summary each instead; `man` gives one tool's arguments.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "app": { "type": "string", "description": "An area id from list_apps, e.g. \"fits\"." }
          },
          "additionalProperties": false
        }
        """#
    )

    var published: @Sendable () async -> [ToolDefinitionWire] = { [] }
    /// The person's guide tools, read when asked.
    var standingRules: @Sendable () async -> [AIGuideSnapshot.StandingRule] = { [] }

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard let wanted = args.app?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty else {
            let rules = await standingRules()
            let brief = [AIGuideSnapshot.briefSection(rules), Self.brief].compactMap { $0 }.joined(separator: "\n\n")
            return Output(standingRules: rules, brief: brief, serverVersion: version, app: nil, tools: nil)
        }
        let tools = await published()
        let areas = ToolMap.areas(tools)
        guard let area = areas.first(where: { $0.id.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw ToolFailureReason.invalidArgument(
                "no area \"\(wanted)\"; list_apps gives them: \(areas.map(\.id).joined(separator: ", "))")
        }
        return Output(brief: nil, serverVersion: version, app: area,
                      tools: ToolMap.entries(inArea: area.id, tools))
    }

    static let brief: String = """
    # Verbinal — macOS companion for the CANFAR Science Platform

    Verbinal is an interactive macOS app that sits between an astronomer and
    the Canadian Astronomy Data Centre (CADC). It exposes its features over
    MCP so an AI agent can search the archive, inspect observation metadata,
    arrange downloads, and prepare science-platform sessions on the user's
    behalf.

    ## Start here

    \(AgentSession.instructions)

    ## Primitives

      * **Observation** — one CAOM-2 observation entity (collection +
        observationID). Carries spatial / temporal / spectral coverage,
        provenance, polarisation, and a list of artefacts (FITS files,
        previews, weight maps).
      * **Plane / Artifact** — a delivery of an observation. Each artifact
        has a URI (`cadc:COLLECTION/path.fits`) and a productType
        (science / weight / preview / aux).
      * **Session** — here, a Skaha science-platform container (notebook /
        desktop / firefly / carta). Has a type, container image, and
        compute resources (cores / RAM / GPU).
      * **VOSpace node** — a file or directory in the user's CADC
        VOSpace storage.

    ## Read surface (call freely, once your session is allowed)

      * `describe_app` — this brief.
      * `get_auth_state` — is the user logged in? what's their displayName?
      * `get_current_view` — what mode the user is in, what's open, AND
        what the person allows without asking (`permissions`). Call this once
        at the start of a session to ground yourself, and re-call if
        you suspect the user has changed settings. When
        `pendingViewerChoice` is set, the Open as… sheet is up — call
        `choose_viewer` before FITS or cube steering tools.
      * `search_observations` — TAP/ADQL query against CADC's archive.
        Accepts target name (resolved server-side), RA/Dec + radius, or
        free-form ADQL. Always cap maxRec sensibly.
      * `vizier_cone_search` — TAP cone-search against any VizieR
        catalogue at CDS (Clement+2001 `V/97/variabls` for globular-cluster
        variables, OGLE/ASAS-SN/ZTF for general transients, etc.).
        Public, no auth, returns parsed rows.
      * `resolve_target` — name → coordinates via the CADC resolver.
      * `get_observation_caom2` — full CAOM-2 metadata document for an
        observation by publisher_id (`ivo://...`).
      * `get_data_links` — preview / thumbnail / file URLs for an
        observation.
      * `list_recent_searches`, `list_saved_queries`, `get_saved_query`.
      * `list_workflows`, `get_workflow`.
      * `list_downloaded_observations`, `get_downloaded_observation`,
        `get_observation_notes`.
      * `list_vospace_path`, `get_vospace_node`, `read_vospace_file`.
      * `list_sessions`, `get_session`, `list_session_types`,
        `list_session_images` (call before `launch_session` AND
        `launch_headless_job`!), `list_recent_launches`.
      * `list_headless_jobs`, `get_headless_job`,
        `get_headless_job_logs`, `get_headless_job_events` —
        background batch jobs (see "Background jobs" below).
      * `find_images_with_packages` — query the local image-content
        cache by package names AND/OR behavioural capabilities
        (`fitsio`, `photutils-iterative-psf`, `gpu`, …). Pure
        read; no Skaha cost. Returns `imageIDs` (matches),
        `candidatesToProbe` (up to 10 unprobed catalogue images
        that fit any `type` filter — your shortlist when matches
        are empty), `allDiscovered` (every probed image), and
        `coverage` (probe-coverage stats). Optional `type:
        "headless"|"notebook"|…` narrows everything to images
        launchable as that session type. See "Image content
        discovery" below.
      * `get_fits_header`, `get_fits_wcs` — local-file FITS introspection;
        `get_fits_spectrum` — the spectrum a table holds (an `_x1d`), as plotted.
      * `list_pending_proposals`, `get_proposal_state`, `list_events` —
        introspect the proposal lifecycle for changes that wait in Pending.
      * `get_session_log`, `explain_log_entry`, `list_session_logs` —
        what happened while you are connected, why, and how long; see
        "When something is slow or fails" below.

    ## Write surface — what the person allows, kind by kind

    Every change you can make is one kind: notes and saved things on this
    Mac, files saved on this Mac, adding to their CANFAR storage, using
    their allocation (sessions and compute; batch jobs and probes),
    sharing, what every assistant is told — and, destructive, removing
    what an assistant made, removing their notes or files, removing or
    replacing in their storage, stopping running work, clearing
    everything at once. The person sets each kind in Settings ▸ AI Agent:
    **Allowed** or **Ask me**. `get_current_view.permissions` gives the
    table; re-read it, as they can change it between turns. Each
    proposing tool's description ends with its kind and what the setting
    does with it.

    ### A kind the person allows — it applies at once

    The call runs the apply and returns
    `{ applied: true, proposalID, kind, summary }`. The change has
    already happened. Confirm the outcome to the user in past tense
    ("Saved your query.", "Notes updated on 5 epochs.", "Launched
    notebook session, id=…"). Do NOT say "I queued a proposal" or "waiting
    for your approval" — there is nothing to review. Per-turn budget does
    NOT apply, so you can pace at the speed the user can read.

    ### A kind the person asks to approve — it waits in Pending

    Your call returns `{ proposalID, kind, summary }` and the proposal
    lands in Pending with your `why`. Tell the user it is awaiting their
    Apply. Optionally poll `get_proposal_state(id)` if you need the
    outcome before continuing. Per-turn cap is 8 outstanding proposals;
    exceed it and you get `perTurnProposalCapExceeded` with the offending
    proposal already withdrawn (no partial pile-up). What every later
    assistant is told — guide tools, tool descriptions — always waits.

    ### Tools (the same, whatever the setting)

      * `save_query`, `update_saved_query`, `delete_saved_query`.
      * `save_workflow` (requires at least one `- [ ]` checklist step),
        `update_workflow`, `set_workflow_step`, `use_workflow`,
        `delete_workflow`.
      * `download_observation` (single), `download_observations_bulk`
        (many → one proposal envelope).
      * `update_observation_note`, `bulk_update_observation_notes`
        (up to 50 → one envelope).
      * `upload_to_vospace` (file from downloaded-observation id),
        `upload_text_to_vospace` (arbitrary in-conversation text up
        to 1 MB — use this to stage scripts/configs without local
        files), `upload_file_to_vospace` (path only — the app streams the
        PUT; poll `list_vospace_path` for size > 0), `download_vospace_file`, `vospace_mkdir`,
        `delete_vospace_node`, `clear_user_site` (wipe
        ~/.local/lib/python3.*/site-packages after a `pip install
        --user` poisoned subsequent jobs).
      * `launch_session`, `delete_session`, `delete_sessions_bulk`
        (up to 50 ids → one envelope, parallel deletes, partial-
        success — use for zombie-cleanup after a launch storm),
        `clear_research_archive`, `launch_headless_job` (see
        "Background jobs" below).
      * `discover_image_packages` (see "Image content discovery"
        below) — schedules a probe job inside the named image to
        enumerate its packages.

    Destructive tools (`delete_*`, `clear_*`, `stop_compute`, …) wait for the
    person unless they allow that kind — by default only removing what an
    assistant made is allowed. Standing instructions — `add_guide_tool`,
    `update_guide_tool`, `delete_guide_tool`, `set_tool_description`,
    `clear_tool_description` — always wait. A call that waits returns a
    `proposalID`; tell the user it is waiting for their approval. Be
    deliberate; the user is trusting you with their data.

    ### Live ops (always run, no proposal either way)

      * `navigate_to` — switch the user's window to a specific section
        (landing/search/research/portal/storage/fitsViewer/cubeViewer/
        aiGuide). Use this
        deliberately to keep the user oriented: "I'll show you the
        search form now" → call `navigate_to(mode: 'search')` →
        actually do the next thing. Independent of the
        "Follow agent activity" toggle; always works.
      * Showing the person the interface — never the data:
        `list_ui_targets` names every control on screen (`kind: all`
        adds text and images; `includeScrolled` what is scrolled away);
        a list's entries are items, and their buttons say whose they
        are ("Relaunch — notebook1"). `point_at_ui` puts one hint up;
        `show_ui_hints` many at once — rings, bubbles with your words,
        numbered for a tour, the rest of the window dimmed. Bubbles
        never overlap or cover what they point at, and keep off images;
        something scrolled away is brought into view first.
        `clear_ui_hints` takes them down, and list_events has
        `hintsDismissed` when the person is done reading. `select_ui`
        selects a list's entry, a tab or a segment as a click does;
        `open_ui` / `close_ui` open and close a folded section, a hidden
        panel, a menu, a sheet, a popover or a file panel on purpose — a sheet by its name, or by pressing the one
        control that opens it (`opens`). None of them chooses inside
        what it opens, presses any other button, or changes data. Hints are not marks: to mark a source
        on an image, kept with its file, use `annotate_fits` or
        `annotate_cube`.
      * `set_search_focus` — pre-positions the search form on RA/Dec.
        Visible the next time the user opens Search (or right now if
        you `navigate_to('search')` afterwards); doesn't yank them
        out of their current screen on its own.
      * `open_fits_file` — opens a downloaded observation's FITS in
        the in-app viewer AND navigates the user's window to the
        viewer mode immediately (so they actually see what you
        opened — no silent action). `open_cube` is the 3D twin for
        spectral cubes. Prefer these (or `open_local_file` with
        `viewer`) when you already know 2D vs 3D, so the Open as…
        sheet never appears.
      * `choose_viewer` — pick 2D FITS vs 3D Cube, or dismiss, when
        the Open as… sheet is showing (`get_current_view.pendingViewerChoice`).
        Viewer steering tools fail until this sheet is resolved.
      * Viewer steering — once something is open you can read and
        drive both viewers live: `get_fits_view` / `set_fits_view`
        (stretch, colormap, cuts, zoom, fit, north-up, tab switch),
        `fits_goto_coordinate` (center + crosshair on RA/Dec),
        `probe_fits_pixel`, and `get_cube_view` / `set_cube_view` /
        `set_cube_camera` (eased rotate/zoom of the 3D volume) /
        `probe_cube_spectrum` for the Cube Viewer. Pass `reveal: true`
        on the cube setters to bring the user's window to the viewer
        so they watch the change land. `list_open_tabs`
        and `close_active_tab` manage the FITS tab strip, and
        `load_saved_search` restores a saved query or recent search
        into the live Search form. Like the other live ops these
        change what the user is looking at — narrate as you go.

    ### Full UI parity — drive the app like the user does

    Every user-facing interaction now has a tool twin (audited in
    docs/agent-ui-parity.md). Highlights beyond the ops above, all
    live view-state unless marked:

      * **Search form**: `get_search_form` / `set_search_form` (every
        constraint field + data-train selections, `execute: true` to
        run), `reset_search_form`, `get_data_train_options` /
        `refresh_data_train`, `select_search_tab`, `quick_search`.
      * **ADQL editor**: `set_adql_editor` (set text or
        `generateFromForm`, optional `execute`) — nothing is saved
        unless you also call `save_query`.
      * **Results table**: `get_search_results` reads exactly what the
        user sees (their live sort/filter/pagination applied);
        `set_results_view` sorts, filters, paginates, shows/hides
        columns, and switches display units; `open_observation_detail`
        opens a row's detail sheet; `export_search_results` writes the
        current table (omit `adql`) or a custom TAP query to Downloads.
      * **Recent searches**: `rename_recent_search`,
        `remove_recent_search`, `clear_recent_searches` (writes).
      * **FITS viewer**: `select_hdu`, `fits_auto_cut`, the blink
        suite (`start_blink` / `set_blink` / `stop_blink`),
        `set_tab_sync` (link crosshair / sync zoom),
        `search_at_crosshair`, and `export_fits_figure` (write —
        annotated publication PNG to Downloads, like
        `export_cube_figure`).
      * **Sessions**: `get_session_events`, `get_session_logs`,
        `open_session` (opens the connect URL in the user's browser).
      * **Image discovery diagnostics**: `list_probe_failures`,
        `get_probe_logs`, `get_image_manifest`,
        `clear_probe_failures` (write). `search_packages` says what
        packages are called; `describe_image` lists a probed image's
        packages with versions.
      * **Remote compute**: `get_compute_state` (set up? session
        state, size, uptime) and `list_compute_runs` (every run, who
        sent it, its status) beside `run_code` / `run_code_output` /
        `start_compute` / `stop_compute`. The Remote Compute screen
        (`navigate_to remoteCompute`): `get_compute_view`,
        `show_compute_run`, `set_compute_snippet` (fills the box; the
        person runs it). `show_storage_folder` opens Storage at a folder
        of the person's home.
      * **Images the catalogue does not list**: `search_image_registry`,
        `list_my_images`, `add_registry_image` (write),
        `remove_registry_image` (write, destructive).
      * **Storage**: `open_vospace_file` (write — download + open;
        NAXIS≥3 shows Open as… and the ack `note` tells you to call
        `choose_viewer`).
      * **Local files**: `list_local_folder`, `open_local_file`
        (optional `viewer: fits|cube` skips the Open as… sheet;
        NAXIS≥3 without `viewer` returns `pendingViewerChoice` and
        you call `choose_viewer`),
        `request_folder_access` (MCP clients get `granted: false` —
        the user grants folders in Storage).
      * **Settings, read-only**: `get_endpoints`,
        `get_compute_config`. Changing settings stays a user decision.

    Steering tools change what the user is looking at — narrate as
    you go, same as the other live ops.

    ### Follow-on navigation (passive, user-controlled)

    Independent of the explicit tools above: when an auto-applied
    write commits, the app navigates the user's window to the section
    where the change is visible (Saved queries → Search, observation
    notes / downloads → Research, VOSpace edits → Storage, sessions →
    Portal). Default ON; the user can disable in Settings ▸ Agents ▸
    Autonomy ▸ "Follow agent activity". You can read the live state
    via the existing `get_current_view.mode` after any write.

    ## Background jobs (headless)

    Headless Skaha sessions are batch jobs — a container runs a single
    command, exits, and you collect logs after. Distinct from
    interactive sessions (notebook / desktop / firefly / carta /
    contributed) which the user clicks into via a browser.

    Use headless when the workflow has a deterministic compute step
    that doesn't need human interaction (image stacks, photometry
    pipelines, batch DataLink fetches, FITS-cube reductions). Use a
    notebook when the user needs to explore interactively.

    Lifecycle: `Pending` → `Running` → terminal (`Completed` /
    `Succeeded` for success, `Failed` / `Error` for failure,
    `Terminating` while shutting down). Skaha drops terminated jobs
    from `list_headless_jobs` after a retention window — fetch logs
    promptly if you need them.

    Tools:
      * `launch_headless_job` — write. Required: `name`, `image` (must
        be from `list_session_images` filtered to `type: "headless"`).
        For Python workloads, pass your source as the `script`
        parameter — the tool hex-encodes it server-side so all the
        Skaha env quirks (`=`, `&`, `"`, `$`, newline, 2 KB cap)
        become invisible to you. For non-Python work use
        `cmd`+`args` directly (mutually exclusive with `script`).
        `env` is an ordered array of {key, value} pairs; values
        containing `=`, `&`, newlines, or exceeding 2 KB are
        REJECTED at the client validator before the request leaves
        (typed `invalidArgument` with the offending key named, not
        a silent drop). `REPLICA_ID` / `REPLICA_COUNT` auto-injected
        per replica. Returns the launched job id(s); ≥ 2 replicas
        spawn parallel containers suffixed `-1, -2, …`. SCHEDULING:
        omitting `cores`/`ram`/`gpus` inherits Skaha's 2/8/0
        default, which often sits Pending 15+ min. For fastest
        start (<60s typical), pass `cores: 1, ram: 1, gpus: 0`
        explicitly — that's the smallest schedulable shape on the
        CANFAR cluster and almost always fits spare capacity.
        Scale up only for production runs you're willing to leave
        queued for hours.
      * `list_headless_jobs` — read. The current jobs, newest first,
        200 a page, with status / phase / image / resources; `counts`
        by phase cover all of them; `phase` / `contains` narrow it.
      * `get_headless_job` — read. Single by id.
      * `get_headless_job_logs` — read. Container stdout/stderr at
        request time plus a typed `state` field (`"ready"` once the
        pod exists; `"pending"` while the job is queued at Skaha
        and no pod has been created yet — Skaha returns 404 during
        that window and the tool surfaces the structured status so
        you don't have to special-case the error).
      * `get_headless_job_events` — read. Kubernetes-level events
        (scheduling, image pulls, OOM kills) plus the same typed
        `state` field as the logs tool. Useful when a job sits in
        `Pending` or `Failed` for unobvious reasons.
      * `delete_session` — destructive. Same id space; works for
        headless and interactive both.

    Polling pattern: 2–5 s while `state` is `"pending"`, slower once
    the pod exists. Don't poll `get_headless_job_logs` in a tight
    loop; fetch when status changes or the user asks.

    ## Image content discovery

    Skaha images are opaque from outside — the agent can't tell what
    Python / R / system packages an image has installed without
    running something inside it. Verbinal solves this by running a
    small probe job inside each image (a headless `bash` script that
    dumps `dpkg -l`, `pip list`, `conda list --export`, `Rscript
    installed.packages()`, etc., to the user's VOSpace), parsing the
    JSON output, and caching the result locally on the user's Mac.

    Tools:
      * `find_images_with_packages` — read. Cache lookup, free.
        Returns image ids that contain ALL listed packages
        (intersection across `dpkg`/`rpm`/`apk`/`python`/`r`/
        `osFamily`/`osVersion` constraints). Use BEFORE picking an
        image for `launch_session` / `launch_headless_job` when the
        user has specific tooling needs ("astropy 6 + tensorflow").
      * `discover_image_packages` — write (semanticWrite, autonomy-
        toggle gated). Schedules a probe job for one image. Cache-
        hit short-circuits with no Skaha cost. Cache-miss runs a
        small headless job (visible in Background Jobs panel; cancel
        with `delete_session`). Pass `force: true` to re-probe after
        an image rebuild. Blocks until the manifest is cached and
        queryable.

    Cache lives at `<App Support>/Verbinal/ImageDiscovery/manifests/`
    on the user's Mac, keyed by image id. Contents persist across app
    relaunches; the in-app discovery sheet (Settings ▸ launch form
    ▸ magnifying-glass next to Container Image) lets the user see
    and re-run discoveries interactively.

    Workflow: `find_images_with_packages` first → if no match,
    `discover_image_packages` for likely candidates → re-query →
    pick → `launch_session` / `launch_headless_job`. Don't probe
    every image speculatively; each costs a real (small) headless
    job.

    ## When something is slow or fails — the session log

    Verbinal keeps a log of your session: every call of yours with the
    CADC and CANFAR requests it made (how long each took, what its
    outcome means), every change anyone made (created, launched,
    downloaded, deleted … — who, and why), the app's decisions with their
    rules (applied at once or held, retried or not, a deadline reached),
    tasks, failed requests, services failing and recovering, sign-in.

      * No answer takes longer than 45 s. A call still working then
        answers that it carries on — on the activity bar, in
        `list_activity` — and is not cut off: ask again shortly for its
        answer. A change still applying answers with its job, to follow
        with `get_job_status`.
      * A reply that asked CADC or CANFAR, took 2 s or more, or failed
        carries a second block, `{"timing": …}`: its requests, a
        `verdict` in one sentence, `retry` (now / later / afterSignIn /
        no) and `logToken`.
      * `explain_log_entry(token)` follows that entry's causes and
        effects, as a story.
      * `get_session_log` gives the log, and `now`: requests still
        waiting and how long of their timeout, tasks running and what
        each waits on, proposals waiting and why, services failing.
      * `get_service_health` probes the services and adds `seenByApp`:
        what Verbinal's own requests showed of each lately.
      * `retry: no` means change the request — asked again, it fails the
        same way. `later` means the service is slow or down.
      * After Verbinal restarts you are in a new session:
        `list_session_logs` finds the one before, and `get_session_log`
        with its `session` reads it.
      * Give every write a `why` — one sentence. The person reads it
        with the change in Pending, above all before a delete, and the
        log keeps it with the change.

    ## Anti-features

      * No multi-window control (you talk to "the app", not a specific
        window).
      * No streaming progress in v1 — long ops complete synchronously
        within the MCP request window. Concrete caps: bulk download
        and bulk-note are 50 items each; single-file upload/download
        of large files (≳ 100 MB) can exceed the MCP transport timeout
        and return `Request timed out` even though the transfer is
        still progressing app-side. Prefer many small operations to
        one giant one until streaming progress lands.
      * No registry credentials over MCP — if you need a private
        image, ask the user to launch it once via the in-app form
        (which has the credential UI) and then re-use that image
        from `list_session_images` going forward.

    ## Workflow shape

    Read first → write → confirm outcome in the language that matches the
    mode. Re-read `get_current_view` if you're uncertain about the mode.
    Don't pile up writes that depend on each other faster than the
    backend can land them; reads are cheap, writes commit real state.

    Specifically: before `launch_session`, ALWAYS call
    `list_session_images` (optionally with `type` filter) and pick a
    real `id` from the result. Hand-typing image strings is the single
    most common cause of avoidable launch failures.
    """
}
