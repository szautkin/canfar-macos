// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Returns a single prose blob orienting an agent to Verbinal's surface:
/// what the app does, what tools are available, what the proposal model
/// is, what's *not* on the menu.
///
/// The brief is static, embedded in source. Single source of truth — when
/// new tools land, edit the brief and the schema together.
struct DescribeAppTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let brief: String
        let serverVersion: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "describe_app",
        description: "Get a prose overview of Verbinal's capabilities, tool surface, and proposal model. Call this once at the start of a session to orient yourself.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        Output(
            brief: Self.brief,
            serverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        )
    }

    static let brief: String = """
    # Verbinal — macOS companion for the CANFAR Science Platform

    Verbinal is an interactive macOS app that sits between an astronomer and
    the Canadian Astronomy Data Centre (CADC). It exposes its features over
    MCP so an AI agent can search the archive, inspect observation metadata,
    arrange downloads, and prepare science-platform sessions on the user's
    behalf.

    ## Primitives

      * **Observation** — one CAOM-2 observation entity (collection +
        observationID). Carries spatial / temporal / spectral coverage,
        provenance, polarisation, and a list of artefacts (FITS files,
        previews, weight maps).
      * **Plane / Artifact** — a delivery of an observation. Each artifact
        has a URI (`cadc:COLLECTION/path.fits`) and a productType
        (science / weight / preview / aux).
      * **Session** — a Skaha science-platform container (notebook /
        desktop / firefly / carta). Has a type, container image, and
        compute resources (cores / RAM / GPU).
      * **VOSpace node** — a file or directory in the user's CADC
        VOSpace storage.

    ## Read surface (call freely)

      * `describe_app` — this brief.
      * `get_auth_state` — is the user logged in? what's their displayName?
      * `get_current_view` — what mode the user is in, what's open, AND
        the current autonomy mode (`autoApplyEnabled`). Call this once
        at the start of a session to ground yourself, and re-call if
        you suspect the user has changed settings.
      * `search_observations` — TAP/ADQL query against CADC's archive.
        Accepts target name (resolved server-side), RA/Dec + radius, or
        free-form ADQL. Always cap maxRec sensibly.
      * `resolve_target` — name → coordinates via the CADC resolver.
      * `get_observation_caom2` — full CAOM-2 metadata document for an
        observation by publisher_id (`ivo://...`).
      * `get_data_links` — preview / thumbnail / file URLs for an
        observation.
      * `list_recent_searches`, `list_saved_queries`, `get_saved_query`.
      * `list_downloaded_observations`, `get_downloaded_observation`,
        `get_observation_notes`.
      * `list_vospace_path`, `get_vospace_node`, `get_vospace_quota`.
      * `list_sessions`, `get_session`, `list_session_types`,
        `list_session_images` (call before `launch_session` AND
        `launch_headless_job`!), `list_recent_launches`.
      * `list_headless_jobs`, `get_headless_job`,
        `get_headless_job_logs`, `get_headless_job_events` —
        background batch jobs (see "Background jobs" below).
      * `get_fits_header`, `get_fits_wcs` — local-file FITS introspection.
      * `list_pending_proposals`, `get_proposal_state`, `list_events` —
        introspect the proposal lifecycle when in strip-confirm mode.

    ## Write surface — TWO MODES, set by user toggle

    The user owns a single Settings switch ("Auto-apply agent writes"),
    default ON once MCP itself is enabled. Read the current value via
    `get_current_view.autoApplyEnabled`.

    ### Auto-apply mode (default) — autonomous

    Your write tool call runs the apply synchronously and returns
    `{ applied: true, proposalID, kind, summary }`. The mutation has
    already happened. Confirm the outcome to the user in past tense
    ("Saved your query.", "Notes updated on 5 epochs.", "Launched
    notebook session, id=…"). Do NOT say "I queued a proposal", "waiting
    for your approval", or "review and Apply" — the strip is empty
    because there is nothing to review. Per-turn budget does NOT apply
    (auto-applied writes don't pile up in the strip), so you can pace at
    the speed the user can read.

    ### Strip-confirm mode — user explicitly opted into review

    Your write tool call returns `{ proposalID, kind, summary }` and the
    proposal lands in the strip. Tell the user it's awaiting their Apply
    click. Optionally poll `get_proposal_state(id)` if you need the
    outcome before continuing. Per-turn cap is 8 outstanding proposals;
    exceed it and you get `perTurnProposalCapExceeded` with the offending
    proposal already withdrawn (no partial pile-up).

    ### Tools (same set, both modes)

      * `save_query`, `update_saved_query`, `delete_saved_query`.
      * `download_observation` (single), `download_observations_bulk`
        (many → one proposal envelope).
      * `update_observation_note`, `bulk_update_observation_notes`
        (up to 50 → one envelope).
      * `upload_to_vospace`, `download_from_vospace`, `vospace_mkdir`,
        `delete_vospace_node`.
      * `launch_session`, `delete_session`, `clear_research_archive`,
        `launch_headless_job` (see "Background jobs" below).

    Destructive tools (`delete_*`, `clear_*`) follow the same toggle as
    semantic writes — there is no separate confirm step for destructive
    operations when auto-apply is on. Be deliberate; the user is trusting
    you with their data.

    ### Live ops (always run, no proposal either way)

      * `navigate_to` — switch the user's window to a specific section
        (landing/search/research/portal/storage/fitsViewer). Use this
        deliberately to keep the user oriented: "I'll show you the
        search form now" → call `navigate_to(mode: 'search')` →
        actually do the next thing. Independent of the
        "Follow agent activity" toggle; always works.
      * `set_search_focus` — pre-positions the search form on RA/Dec.
        Visible the next time the user opens Search (or right now if
        you `navigate_to('search')` afterwards); doesn't yank them
        out of their current screen on its own.
      * `open_fits_file` — opens a downloaded observation's FITS in
        the in-app viewer AND navigates the user's window to the
        viewer mode immediately (so they actually see what you
        opened — no silent action).

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
        Optional: `cmd` (the command to run), `args` (single
        space-separated string), `env` (array of {key, value} pairs;
        `REPLICA_ID` and `REPLICA_COUNT` are auto-injected per
        replica), `cores` / `ram` / `gpus`, `replicas` (1–50).
        Returns the launched job id(s); ≥ 2 replicas spawn parallel
        containers with names suffixed `-1, -2, …`. Partial-replica
        failure: the applier persists the replicas that DID land and
        the call fails with `backendError` describing which replica
        failed and how many already running.
      * `list_headless_jobs` — read. Snapshot of all current jobs
        with status / phase / image / resources.
      * `get_headless_job` — read. Single by id.
      * `get_headless_job_logs` — read. Container stdout/stderr at
        request time (snapshot, not a live tail).
      * `get_headless_job_events` — read. Kubernetes-level events
        (scheduling, image pulls, OOM kills). Useful when a job sits
        in `Pending` or `Failed` for unobvious reasons.
      * `delete_session` — destructive. Same id space; works for
        headless and interactive both.

    Polling pattern: 2–5 s while `Pending`/`Running`, backing off after
    a few minutes. Don't poll `get_headless_job_logs` in a tight loop;
    fetch when the user asks or when status changes.

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
