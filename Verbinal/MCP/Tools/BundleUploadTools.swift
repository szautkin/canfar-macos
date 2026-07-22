// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - upload_file_to_vospace

/// Upload an arbitrary local file (by absolute path) to a VOSpace path.
/// Unlike `upload_to_vospace`, this is not tied to a downloaded
/// observation — any regular file the app can read qualifies.
struct UploadFileToVOSpaceTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let localPath: String
        let remotePath: String
    }

    struct Payload: Codable, Sendable {
        let localPath: String
        let remotePath: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "upload_file_to_vospace",
        description: "Upload a local file (absolute path) to a VOSpace path. `localPath` must point at an existing regular file; `remotePath` is the destination path inside the user's VOSpace. Runs immediately when auto-apply is on; otherwise queues to the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["localPath", "remotePath"],
          "properties": {
            "localPath":  { "type": "string", "description": "Absolute path to an existing local file." },
            "remotePath": { "type": "string", "description": "Destination path in the user's VOSpace." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard args.localPath.hasPrefix("/") else {
            throw ToolFailureReason.invalidArgument("localPath must be an absolute path")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: args.localPath, isDirectory: &isDirectory) else {
            throw ToolFailureReason.unknownTarget("local file \(args.localPath)")
        }
        guard !isDirectory.boolValue else {
            throw ToolFailureReason.invalidArgument("localPath is a directory; point at a regular file")
        }
        let remotePath = args.remotePath.trimmingCharacters(in: .whitespaces)
        guard !remotePath.isEmpty else {
            throw ToolFailureReason.invalidArgument("remotePath is empty")
        }
        guard !remotePath.split(separator: "/").contains("..") else {
            throw ToolFailureReason.invalidArgument("remotePath must not contain '..' segments")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: args.localPath)
        let sizeBytes = (attributes?[.size] as? Int64) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        let filename = (args.localPath as NSString).lastPathComponent
        return try ProposalPlan.encoding(
            kind: "upload_file_to_vospace",
            summary: "Upload \(filename) (\(sizeText)) to VOSpace \(remotePath)",
            payload: Payload(localPath: args.localPath, remotePath: remotePath)
        )
    }
}

/// Concrete handler that runs when the user clicks Apply on an
/// `upload_file_to_vospace` proposal (or immediately under auto-apply).
struct UploadFileToVOSpaceApplier: ProposalApplier {
    let kind = "upload_file_to_vospace"
    let upload: @Sendable (_ fileURL: URL, _ remotePath: String) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(UploadFileToVOSpaceTool.Payload.self, from: proposal.payload)
        let fileURL = URL(fileURLWithPath: payload.localPath)
        do {
            try await upload(fileURL, payload.remotePath)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("upload failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}

// MARK: - export_research_bundle

/// Export the user's research archive as a portable bundle in Downloads,
/// optionally including copies of the downloaded files and optionally
/// uploading the bundle to VOSpace afterwards.
struct ExportResearchBundleTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        var includeFileCopies: Bool?
        var uploadToVOSpace: Bool?
    }

    struct Payload: Codable, Sendable {
        let includeFileCopies: Bool
        let uploadToVOSpace: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "export_research_bundle",
        description: "Export the research archive as a portable bundle in the user's Downloads folder. `includeFileCopies` also copies the downloaded data files into the bundle (larger, but self-contained); `uploadToVOSpace` additionally uploads the finished bundle to the user's VOSpace. Both default to false. Runs immediately when auto-apply is on; otherwise queues to the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "includeFileCopies": { "type": "boolean", "description": "Also copy the downloaded data files into the bundle. Default false." },
            "uploadToVOSpace":   { "type": "boolean", "description": "Upload the finished bundle to the user's VOSpace. Default false." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let includeFileCopies = args.includeFileCopies ?? false
        let uploadToVOSpace = args.uploadToVOSpace ?? false
        var summary = "Export research bundle to Downloads"
        if includeFileCopies {
            summary += " (with file copies)"
        }
        if uploadToVOSpace {
            summary += " + upload to VOSpace"
        }
        return try ProposalPlan.encoding(
            kind: "export_research_bundle",
            summary: summary,
            payload: Payload(
                includeFileCopies: includeFileCopies,
                uploadToVOSpace: uploadToVOSpace
            )
        )
    }
}

/// Concrete handler that runs when the user clicks Apply on an
/// `export_research_bundle` proposal (or immediately under auto-apply).
struct ExportResearchBundleApplier: ProposalApplier {
    let kind = "export_research_bundle"
    let run: @Sendable (_ includeFileCopies: Bool, _ uploadToVOSpace: Bool) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(ExportResearchBundleTool.Payload.self, from: proposal.payload)
        do {
            try await run(payload.includeFileCopies, payload.uploadToVOSpace)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("export failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
