// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os
import VerbinalKit

/// What an assistant made, told apart from what the person made, so that
/// removing it is "Remove what an assistant made" — which the person may
/// allow — while removing theirs asks (plan 30 A6). A thing is a key: what
/// it is and its id — `vospace:<path from home>`, `savedQuery:<id>`,
/// `workflow:<id>`, `bookmark:<id>`, `registryImage:<id>`, `research:<id>`,
/// `session:<id>`.
enum AssistantMade {
    /// What an applied change made: from what it was asked (a path, an id it
    /// chose) or what it answered (the id it made).
    static func made(by proposal: PendingProposal, result: Data?, username: String) -> [String] {
        let payload = fields(proposal.payload)
        let answer = result.flatMap { try? JSONDecoder().decode(AutoAppliedAck.Extra.self, from: $0) }
        func answered(_ space: String) -> [String] {
            ((answer?.succeeded ?? []) + [answer?.id].compactMap { $0 }).map { "\(space):\($0)" }
        }
        switch proposal.toolName {
        case "save_query": return [payload["id"]].compactMap { $0 }.map { "savedQuery:\($0)" }
        case "save_workflow", "use_workflow": return answered("workflow")
        case "save_fits_bookmark": return answered("bookmark")
        case "add_registry_image": return [payload["imageID"]].compactMap { $0 }.map { "registryImage:\($0)" }
        case "download_observation", "download_cutout", "save_observation_to_research", "download_observations_bulk":
            return answered("research")
        case "launch_session", "launch_headless_job": return answered("session")
        case "create_vospace_folder", "vospace_mkdir":
            guard let parent = payload["parentPath"], let name = payload["folderName"] else { return [] }
            return [vospace(parent.isEmpty ? name : "\(parent)/\(name)", username: username)].compactMap { $0 }
        case "upload_text_to_vospace", "upload_to_vospace":
            return [payload["vospacePath"].flatMap { vospace($0, username: username) }].compactMap { $0 }
        case "upload_file_to_vospace":
            return [payload["remotePath"].flatMap { vospace($0, username: username) }].compactMap { $0 }
        default: return []
        }
    }

    /// What a removal removes; nil for a change that removes nothing these keys name.
    static func removed(by proposal: PendingProposal, username: String) -> [String]? {
        let payload = fields(proposal.payload)
        let key: String? = switch proposal.toolName {
        case "delete_saved_query": payload["id"].map { "savedQuery:\($0)" }
        case "delete_workflow": payload["id"].map { "workflow:\($0)" }
        case "delete_fits_bookmark": payload["id"].map { "bookmark:\($0)" }
        case "remove_registry_image": payload["imageID"].map { "registryImage:\($0)" }
        case "delete_downloaded_observation", "remove_downloaded_file": payload["id"].map { "research:\($0)" }
        case "delete_session": payload["id"].map { "session:\($0)" }
        case "delete_vospace_node": payload["path"].flatMap { vospace($0, username: username) }
        default: nil
        }
        return key.map { [$0] }
    }

    /// An upload's VOSpace key: what it would write over.
    static func uploadTarget(of proposal: PendingProposal, username: String) -> String? {
        let payload = fields(proposal.payload)
        switch proposal.toolName {
        case "upload_text_to_vospace", "upload_to_vospace": return payload["vospacePath"].flatMap { vospace($0, username: username) }
        case "upload_file_to_vospace": return payload["remotePath"].flatMap { vospace($0, username: username) }
        default: return nil
        }
    }

    /// A VOSpace path as a key, from home — as the Storage screen and the
    /// tools read a path (`VOSpaceRelativePath`).
    static func vospace(_ path: String, username: String) -> String? {
        (try? VOSpaceRelativePath.normalize(path, username: username)).flatMap { $0.isEmpty ? nil : "vospace:\($0)" }
    }

    /// A VOSpace key's path; nil for any other key.
    static func vospacePath(_ key: String) -> String? {
        key.hasPrefix("vospace:") ? String(key.dropFirst("vospace:".count)) : nil
    }

    /// A payload's top-level fields that are strings.
    private static func fields(_ payload: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return [:] }
        return object.compactMapValues { $0 as? String }
    }
}

/// Which kind a proposal is, by what it acts on (plan 30 A6): a removal of
/// only what an assistant made is that, and an upload over a file replaces
/// it. Everything else is its tool's kind. What it looks up comes in, so the
/// rule is tested without VOSpace.
struct ChangeKindResolver: Sendable {
    let username: String
    /// Whether an assistant made the thing a key names.
    let isMade: @Sendable (String) async -> Bool
    /// Every VOSpace path under a folder, from home; nil when it cannot be told.
    let subtree: @Sendable (String) async -> [String]?
    /// Whether a VOSpace path holds something now; nil when it cannot be told.
    let exists: @Sendable (String) async -> Bool?

    func kind(of proposal: PendingProposal) async -> ChangeKind {
        let kind = ChangeCatalog.kind(of: proposal)
        if let target = AssistantMade.uploadTarget(of: proposal, username: username) {
            guard let path = AssistantMade.vospacePath(target), let there = await exists(path) else {
                return .removeFromStorage    // Cannot tell: it may write over a file.
            }
            guard there else { return kind }
            return await isMade(target) ? .removeAssistantMade : .removeFromStorage
        }
        guard kind.isDestructive, kind != .everythingAtOnce,
              let keys = AssistantMade.removed(by: proposal, username: username), !keys.isEmpty else { return kind }
        for key in keys {
            guard await isMade(key) else { return kind }
            // A folder goes with everything in it: all of it must be an assistant's.
            if let path = AssistantMade.vospacePath(key) {
                guard let inside = await subtree(path) else { return kind }
                for child in inside {
                    guard let childKey = AssistantMade.vospace(child, username: username), await isMade(childKey) else {
                        return kind
                    }
                }
            }
        }
        return .removeAssistantMade
    }
}

/// The keys of what assistants made, kept on this Mac. Written when an
/// assistant's change applies; what the person made is never in it.
@MainActor
final class AssistantMadeStore {
    struct Entry: Codable, Equatable, Sendable {
        let key: String
        let session: UUID?
        let at: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private let persistence: DiskPersistence<[Entry]>?

    init(persistence: DiskPersistence<[Entry]>? = AssistantMadeStore.productionPersistence) {
        self.persistence = persistence
        if case .value(let stored) = persistence?.readResult() {
            entries = Dictionary(stored.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    nonisolated static let productionPersistence = DiskPersistence<[Entry]>(
        subdirectory: "Verbinal", fileName: "assistant_made.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "AssistantMade"))

    func contains(_ key: String) -> Bool { entries[key] != nil }

    /// What an assistant's applied change made, and what it removed.
    func applied(_ proposal: PendingProposal, result: Data?, username: String) {
        let made = AssistantMade.made(by: proposal, result: result, username: username)
        let removed = AssistantMade.removed(by: proposal, username: username) ?? []
        guard !made.isEmpty || removed.contains(where: { entries[$0] != nil }) else { return }
        for key in made { entries[key] = Entry(key: key, session: proposal.session, at: Date()) }
        for key in removed { entries[key] = nil }
        _ = persistence?.write(Array(entries.values))
    }
}
