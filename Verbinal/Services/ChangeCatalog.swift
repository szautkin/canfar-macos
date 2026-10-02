// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Which kind of change each tool makes (plan 30 A): the one place a tool's
/// kind is set, and what the person's setting in Settings ▸ AI Agent decides
/// by. A test holds every proposing tool to having one.
enum ChangeCatalog {
    static let kindByTool: [String: ChangeKind] = {
        var table: [String: ChangeKind] = [:]
        func put(_ kind: ChangeKind, _ tools: [String]) { for tool in tools { table[tool] = kind } }
        put(.notesAndSaved, ["update_observation_note", "bulk_update_observation_notes", "save_query",
                             "update_saved_query", "rename_recent_search", "save_workflow", "update_workflow",
                             "use_workflow", "set_workflow_step", "save_fits_bookmark",
                             "save_observation_to_research", "add_registry_image"])
        put(.filesOnMac, ["download_observation", "download_observations_bulk", "download_cutout",
                          "download_vospace_file", "download_from_vospace", "open_vospace_file", "export_search_results",
                          "export_fits_figure", "export_cube_figure", "export_research_bundle",
                          "export_session_log"])
        put(.addToStorage, ["create_vospace_folder", "vospace_mkdir", "upload_text_to_vospace",
                            "upload_file_to_vospace", "upload_to_vospace"])
        put(.allocationSessions, ["launch_session", "renew_session", "start_compute", "run_code"])
        put(.allocationBatch, ["launch_headless_job", "discover_image_packages"])
        put(.sharing, ["set_vospace_acl"])
        // Removing a guide tool changes what assistants are told as surely as
        // adding one: it could remove the person's own rule.
        put(.standingInstruction, ["add_guide_tool", "update_guide_tool", "delete_guide_tool",
                                   "set_tool_description", "clear_tool_description"])
        put(.removeNotesAndSaved, ["delete_saved_query", "remove_recent_search", "delete_workflow",
                                   "delete_fits_bookmark", "remove_registry_image", "clear_probe_failures"])
        put(.removeFilesOnMac, ["remove_downloaded_file", "delete_downloaded_observation"])
        put(.removeFromStorage, ["delete_vospace_node"])
        put(.stopWork, ["delete_session", "stop_compute"])
        put(.everythingAtOnce, ["clear_recent_searches", "clear_research_archive", "clear_user_site",
                                "delete_sessions_bulk", "delete_session_logs"])
        return table
    }()

    /// The tool's kind; nil for a tool that changes nothing.
    static func kind(ofTool name: String) -> ChangeKind? { kindByTool[name] }

    /// This proposal's kind: its tool's. A change the catalogue does not
    /// know asks, as the most careful kind there is to ask about.
    static func kind(of proposal: PendingProposal) -> ChangeKind {
        kind(ofTool: proposal.toolName) ?? .everythingAtOnce
    }

    /// Whether it applies at once under `permissions`, and the rule that says so.
    static func decision(for proposal: PendingProposal, permissions: ChangePermissions) -> AutoApplyDecision {
        decision(kind: kind(of: proposal), permissions: permissions)
    }

    static func decision(kind: ChangeKind, permissions: ChangePermissions) -> AutoApplyDecision {
        let atOnce = AutoApplyPolicy.appliesAtOnce(kind, permissions: permissions)
        return AutoApplyDecision(appliesAtOnce: atOnce, rule: AutoApplyPolicy.rule(forChange: kind, appliedAtOnce: atOnce))
    }

    /// The kinds as an assistant reads them (`get_current_view.permissions`).
    struct Permission: Encodable, Sendable, Equatable {
        let kind: String
        let title: String
        let covers: String
        let destructive: Bool
        let allowed: Bool
        let settable: Bool
    }

    static func table(_ permissions: ChangePermissions) -> [Permission] {
        ChangeKind.allCases.map {
            Permission(kind: $0.rawValue, title: $0.title, covers: $0.summary, destructive: $0.isDestructive,
                       allowed: permissions.allows($0), settable: $0.isSettable)
        }
    }
}
