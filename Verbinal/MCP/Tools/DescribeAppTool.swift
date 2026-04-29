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
    behalf — under user-confirmed control.

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
        compute resources (cores / RAM / GPU). User-launched.
      * **VOSpace node** — a file or directory in the user's CADC
        VOSpace storage.

    ## Read surface (call freely, no proposal needed)

      * `describe_app` — this brief.
      * `get_auth_state` — is the user logged in? what's their displayName?
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
        `list_recent_launches`.
      * `get_fits_header`, `get_fits_wcs` — local-file FITS introspection.

    ## Write surface (proposal-gated)

    Every state-changing tool **enqueues a proposal**. The user reviews it
    in the strip and clicks **Apply** or **Reject**. You receive back the
    proposal id and can poll `get_proposal_state`. There's a per-session
    cap of 8 outstanding proposals — exceed it and your tool call fails
    with `perTurnProposalCapExceeded`.

      * `save_query`, `update_saved_query`, `delete_saved_query`.
      * `download_observation` (single), `download_observations_bulk`
        (many → ONE proposal).
      * `update_observation_note`.
      * `upload_to_vospace`, `download_from_vospace`, `vospace_mkdir`,
        `delete_vospace_node`.
      * `launch_session`, `delete_session`.

    ## Anti-features

      * No autonomous downloads / launches — every write is user-gated.
      * No multi-window control (you talk to "the app", not a specific
        window).
      * No streaming progress in v1 — long ops complete synchronously
        (cap your batches: bulk download is limited to 10 files).

    ## Workflow shape

    Read first → propose write → wait for the user → continue. Don't loop
    on a write without checking `get_proposal_state`. Don't pile up
    proposals; the cap is there to keep the user's strip readable.
    """
}
