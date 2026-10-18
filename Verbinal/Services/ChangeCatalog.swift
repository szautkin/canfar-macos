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
                             "save_observation_to_research", "add_registry_image", "resolve_sync_conflict"])
        put(.filesOnMac, ["download_observation", "download_observations_bulk", "download_cutout",
                          "download_vospace_file", "download_from_vospace", "open_vospace_file", "export_search_results",
                          "export_fits_figure", "export_cube_figure", "export_research_bundle",
                          "export_session_log", "get_research_file_from_storage"])
        put(.addToStorage, ["create_vospace_folder", "vospace_mkdir", "upload_text_to_vospace",
                            "upload_file_to_vospace", "upload_to_vospace", "send_research_file_to_storage",
                            "move_research_files"])
        put(.allocationSessions, ["launch_session", "renew_session", "start_compute", "run_code"])
        put(.allocationBatch, ["launch_headless_job", "discover_image_packages"])
        put(.sharing, ["set_vospace_acl"])
        // Removing a guide tool changes what assistants are told as surely as
        // adding one: it could remove the person's own rule.
        put(.standingInstruction, ["add_guide_tool", "update_guide_tool", "delete_guide_tool",
                                   "set_tool_description", "clear_tool_description"])
        put(.removeNotesAndSaved, ["delete_saved_query", "remove_recent_search", "delete_workflow",
                                   "delete_fits_bookmark", "remove_registry_image", "clear_probe_failures"])
        put(.removeFilesOnMac, ["remove_downloaded_file", "delete_downloaded_observation", "remove_research_file_from_mac"])
        put(.removeFromStorage, ["delete_vospace_node", "remove_research_file_from_storage"])
        put(.stopWork, ["delete_session", "stop_compute"])
        put(.everythingAtOnce, ["clear_recent_searches", "clear_research_archive", "clear_user_site",
                                "delete_sessions_bulk", "delete_session_logs"])
        return table
    }()

    /// The tool's kind; nil for a tool that changes nothing.
    static func kind(ofTool name: String) -> ChangeKind? { kindByTool[name] }

    /// Tools whose kind is what each call does, not one of the tool's: a
    /// choice on a sync conflict (plan 45), Move To's moves (plan 46).
    static let kindByCall: Set<String> = ["resolve_sync_conflict", "move_research_files"]

    /// The closing sentence of a proposing tool's description: its kind, and
    /// what the person's setting does with it now. Live, plan 46 L8:
    /// move_research_files said it "applies at once", its tool's kind, while
    /// the move it made waited as a removal.
    static func toolRule(_ tool: String, permissions: ChangePermissions) -> String? {
        if kindByCall.contains(tool) {
            return "Its kind is what each call does, as said above; whether that applies at once or waits in Pending is the person's setting for that kind. `get_current_view.permissions` gives every kind."
        }
        return kind(ofTool: tool).map { AutoApplyPolicy.toolSentence(forChange: $0, permissions: permissions) }
    }

    /// This proposal's kind: its tool's — a choice on a sync conflict by
    /// what it does, and to which collection (plan 45). A change the
    /// catalogue does not know asks, as the most careful kind there is to ask about.
    static func kind(of proposal: PendingProposal) -> ChangeKind {
        if proposal.toolName == "resolve_sync_conflict" {
            return syncConflictKind(of: proposal.payload) ?? .everythingAtOnce
        }
        if proposal.toolName == "move_research_files" {
            return moveKind(of: proposal.payload) ?? .everythingAtOnce
        }
        return kind(ofTool: proposal.toolName) ?? .everythingAtOnce
    }

    /// Research's Move To (plan 46): by the copy it removes, or where it copies.
    private static func moveKind(of payload: Data) -> ChangeKind? {
        struct Move: Decodable {
            let to: String
            let removes: String?
        }
        guard let move = try? JSONDecoder().decode(Move.self, from: payload) else { return nil }
        switch (move.removes, move.to) {
        case ("storage"?, _): return .removeFromStorage
        case ("mac"?, _): return .removeFilesOnMac
        case (nil, "storage"): return .addToStorage
        case (nil, "mac"): return .filesOnMac
        default: return nil
        }
    }

    /// A choice on a sync conflict: a guide is what every assistant is
    /// told; the choice that removes the item removes; any other keeps.
    private static func syncConflictKind(of payload: Data) -> ChangeKind? {
        struct Choice: Decodable {
            let collection: String
            let removes: Bool
        }
        guard let choice = try? JSONDecoder().decode(Choice.self, from: payload) else { return nil }
        if choice.collection == "guides" { return .standingInstruction }
        return choice.removes ? .removeNotesAndSaved : .notesAndSaved
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
