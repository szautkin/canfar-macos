// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - upload_to_vospace

/// Upload a downloaded observation to a VOSpace path. Source is a
/// downloaded_observation_id rather than a free-form path so the
/// applier can use the security-scoped bookmark captured at download
/// time — that's the only way a sandboxed app can read the file.
struct UploadToVOSpaceTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let downloaded_observation_id: String
        let vospace_path: String
    }

    struct Payload: Codable, Sendable {
        let downloadedObservationID: String
        let vospacePath: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "upload_to_vospace",
        description: "Upload a downloaded observation's local file to a VOSpace path.",
        schema: #"""
        {
          "type": "object",
          "required": ["downloaded_observation_id", "vospace_path"],
          "properties": {
            "downloaded_observation_id": { "type": "string" },
            "vospace_path":              { "type": "string", "description": "Target VOSpace path (no leading slash). Includes the destination filename." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard UUID(uuidString: args.downloaded_observation_id) != nil else {
            throw ToolFailureReason.invalidArgument("downloaded_observation_id is not a UUID")
        }
        guard !args.vospace_path.isEmpty else {
            throw ToolFailureReason.invalidArgument("vospace_path is empty")
        }
        return try ProposalPlan.encoding(
            kind: "upload_to_vospace",
            summary: "Upload to VOSpace: \(args.vospace_path)",
            payload: Payload(
                downloadedObservationID: args.downloaded_observation_id,
                vospacePath: args.vospace_path
            )
        )
    }
}

// MARK: - download_from_vospace

/// Download a VOSpace file to the user's Downloads directory.
struct DownloadFromVOSpaceTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let vospace_path: String
    }

    struct Payload: Codable, Sendable {
        let vospacePath: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "download_from_vospace",
        description: "Download a VOSpace file to the user's Downloads folder.",
        schema: #"""
        {
          "type": "object",
          "required": ["vospace_path"],
          "properties": {
            "vospace_path": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.vospace_path.isEmpty else {
            throw ToolFailureReason.invalidArgument("vospace_path is empty")
        }
        return try ProposalPlan.encoding(
            kind: "download_from_vospace",
            summary: "Download from VOSpace: \(args.vospace_path)",
            payload: Payload(vospacePath: args.vospace_path)
        )
    }
}

// MARK: - vospace_mkdir

struct VOSpaceMkdirTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let parent_path: String
        let folder_name: String
    }

    struct Payload: Codable, Sendable {
        let parentPath: String
        let folderName: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "vospace_mkdir",
        description: "Create a folder under a VOSpace path.",
        schema: #"""
        {
          "type": "object",
          "required": ["parent_path", "folder_name"],
          "properties": {
            "parent_path": { "type": "string" },
            "folder_name": { "type": "string", "minLength": 1 }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.folder_name.isEmpty else {
            throw ToolFailureReason.invalidArgument("folder_name is empty")
        }
        return try ProposalPlan.encoding(
            kind: "vospace_mkdir",
            summary: "Create VOSpace folder: \(args.parent_path)/\(args.folder_name)",
            payload: Payload(parentPath: args.parent_path, folderName: args.folder_name)
        )
    }
}

// MARK: - delete_vospace_node (destructive)

struct DeleteVOSpaceNodeTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let path: String
    }

    struct Payload: Codable, Sendable {
        let path: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_vospace_node",
        description: "Permanently delete a VOSpace node (file or folder). Destructive — user must confirm in strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": { "path": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.path.isEmpty else {
            throw ToolFailureReason.invalidArgument("path is empty")
        }
        return try ProposalPlan.encoding(
            kind: "delete_vospace_node",
            summary: "Delete from VOSpace: \(args.path)",
            payload: Payload(path: args.path)
        )
    }
}

// MARK: - Appliers

/// All VOSpace appliers share the same dependency shape: the service
/// plus a closure that resolves the username from @MainActor AppState.
private struct VOSpaceAppliers {
    let service: VOSpaceBrowserService
    let username: @Sendable () async -> String
    let observationStore: ObservationStore
    let downloadsDirectory: @Sendable () -> URL
    let activity: AgentActivityStore
}

struct UploadToVOSpaceApplier: ProposalApplier {
    let kind = "upload_to_vospace"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(UploadToVOSpaceTool.Payload.self, from: proposal.payload)
        guard let id = UUID(uuidString: payload.downloadedObservationID) else {
            throw ProposalApplyError.backendError("invalid downloaded_observation_id")
        }
        let username = await context.username()
        guard !username.isEmpty else { throw ProposalApplyError.backendError("not authenticated") }
        guard let obs = await MainActor.run(body: { context.observationStore.observations.first(where: { $0.id == id }) }) else {
            throw ProposalApplyError.backendError("downloaded_observation not found")
        }
        // Resolve the local URL via the security-scoped bookmark when present.
        let url: URL
        var didStart = false
        if let bookmark = obs.bookmarkData {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                didStart = url.startAccessingSecurityScopedResource()
            } catch {
                throw ProposalApplyError.backendError("bookmark resolution: \(error.localizedDescription)")
            }
        } else {
            url = obs.localURL
        }
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            try await context.service.uploadFile(username: username, remotePath: payload.vospacePath, fileURL: url)
        } catch {
            throw ProposalApplyError.backendError("upload failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            context.activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

struct DownloadFromVOSpaceApplier: ProposalApplier {
    let kind = "download_from_vospace"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DownloadFromVOSpaceTool.Payload.self, from: proposal.payload)
        let username = await context.username()
        guard !username.isEmpty else { throw ProposalApplyError.backendError("not authenticated") }

        let result: (tempURL: URL, filename: String)
        do {
            result = try await context.service.downloadFile(username: username, path: payload.vospacePath)
        } catch {
            throw ProposalApplyError.backendError("download failed: \(error.localizedDescription)")
        }
        let dir = context.downloadsDirectory()
        let target = dir.appendingPathComponent(result.filename)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: result.tempURL, to: target)
        } catch {
            try? FileManager.default.removeItem(at: result.tempURL)
            throw ProposalApplyError.backendError("move into Downloads: \(error.localizedDescription)")
        }
        await MainActor.run {
            context.activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

struct VOSpaceMkdirApplier: ProposalApplier {
    let kind = "vospace_mkdir"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(VOSpaceMkdirTool.Payload.self, from: proposal.payload)
        let username = await context.username()
        guard !username.isEmpty else { throw ProposalApplyError.backendError("not authenticated") }
        do {
            try await context.service.createFolder(
                username: username,
                parentPath: payload.parentPath,
                folderName: payload.folderName
            )
        } catch {
            throw ProposalApplyError.backendError("mkdir failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            context.activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

struct DeleteVOSpaceNodeApplier: ProposalApplier {
    let kind = "delete_vospace_node"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DeleteVOSpaceNodeTool.Payload.self, from: proposal.payload)
        let username = await context.username()
        guard !username.isEmpty else { throw ProposalApplyError.backendError("not authenticated") }
        do {
            try await context.service.deleteNode(username: username, path: payload.path)
        } catch {
            throw ProposalApplyError.backendError("delete failed: \(error.localizedDescription)")
        }
        await MainActor.run {
            context.activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

/// Build all four VOSpace appliers in one call. Lives next to the tools
/// so the contract between them stays visible.
@MainActor
func makeVOSpaceAppliers(
    service: VOSpaceBrowserService,
    observationStore: ObservationStore,
    appState: AppState,
    activity: AgentActivityStore
) -> [any ProposalApplier] {
    let context = VOSpaceAppliers(
        service: service,
        username: { @Sendable in await MainActor.run { appState.username } },
        observationStore: observationStore,
        downloadsDirectory: { @Sendable in
            (try? FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        },
        activity: activity
    )
    return [
        UploadToVOSpaceApplier(context: context),
        DownloadFromVOSpaceApplier(context: context),
        VOSpaceMkdirApplier(context: context),
        DeleteVOSpaceNodeApplier(context: context),
    ]
}
