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
        description: "Upload a local file by path. The MCP call only sends the path (bytes stay on disk). The app starts a streaming PUT immediately and this tool returns without waiting for the transfer — poll `list_vospace_path` until the node size is > 0. `localPath` must be an existing regular file; `remotePath` is inside the user's VOSpace. A 10-minute app-side deadline still applies to the PUT. Runs immediately when auto-apply is on; otherwise queues to the proposal strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["localPath", "remotePath"],
          "properties": {
            "localPath":  { "type": "string", "description": "Absolute path to an existing local file." },
            "remotePath": { "type": "string", "description": "Destination path relative to the user's VOSpace home; `/home/<user>/…` is accepted." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let fileURL = Self.resolveLocalFileURL(args.localPath)
        guard fileURL.path.hasPrefix("/") else {
            throw ToolFailureReason.invalidArgument("localPath must be an absolute path")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
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
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes?[.size] as? Int64) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        let filename = fileURL.lastPathComponent
        return try ProposalPlan.encoding(
            kind: "upload_file_to_vospace",
            summary: "Upload \(filename) (\(sizeText)) to VOSpace \(remotePath)",
            payload: Payload(localPath: fileURL.path, remotePath: remotePath)
        )
    }

    /// Tilde + sandbox Downloads mapping so the applier PUT reads a path
    /// the sandboxed process can actually open (same helper as `open_local_file`).
    static func resolveLocalFileURL(_ path: String) -> URL {
        #if os(macOS)
        if let url = LocalFolderAccessStore.readableURL(for: path, directory: false) {
            return url
        }
        return LocalFolderAccessStore.resolveSandboxPath(
            URL(fileURLWithPath: LocalFolderAccessStore.expandedPath(path)))
        #else
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        #endif
    }

    /// Copy into the app temp directory so the PUT reads a file the
    /// sandbox always owns. `URLSession.upload(fromFile:)` on a
    /// user-facing Downloads path from a detached task was sending an
    /// empty body — CADC creates the node at 0 bytes (2026-08-28 QA).
    static func stageCopyForUpload(_ source: URL) throws -> URL {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(
            "verbinal-vospace-put-\(UUID().uuidString)-\(source.lastPathComponent)")
        if FileManager.default.fileExists(atPath: staged.path) {
            try FileManager.default.removeItem(at: staged)
        }
        try FileManager.default.copyItem(at: source, to: staged)
        let size = (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw ProposalApplyError.backendError(
                "staged upload is 0 bytes — the app could not read \(source.path)")
        }
        return staged
    }
}

/// Concrete handler that accepts a local path and starts the streaming
/// PUT **app-side**. The MCP / auto-apply round-trip must not wait for
/// the transfer: Cursor's JSON-RPC client aborts around 60s (`-32001`)
/// and cancelling that wait also cancelled the URLSession PUT, leaving
/// a 0-byte VOSpace node (2026-08-28 QA). `Task.detached` keeps the
/// PUT off the MCP cancellation tree.
struct UploadFileToVOSpaceApplier: ProposalApplier, ResultReportingApplier {
    let kind = "upload_file_to_vospace"
    let upload: @Sendable (_ fileURL: URL, _ remotePath: String) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(UploadFileToVOSpaceTool.Payload.self, from: proposal.payload)
        let fileURL = UploadFileToVOSpaceTool.resolveLocalFileURL(payload.localPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ProposalApplyError.backendError("local file missing: \(payload.localPath)")
        }
        let staged: URL
        do {
            staged = try UploadFileToVOSpaceTool.stageCopyForUpload(fileURL)
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("cannot stage local file: \(error.localizedDescription)")
        }
        let upload = self.upload
        let activity = self.activity
        let remotePath = payload.remotePath
        let kind = self.kind
        Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: staged) }
            do {
                try await withApplierTimeout(seconds: 600, label: "upload_file_to_vospace") {
                    try await upload(staged, remotePath)
                }
                await MainActor.run {
                    activity.append(.applied(proposal: proposal, kind: kind))
                }
            } catch {
                let msg: String
                if let pa = error as? ProposalApplyError, case .backendError(let text) = pa {
                    msg = text
                } else {
                    msg = error.localizedDescription
                }
                await MainActor.run {
                    activity.append(.live(
                        kind: kind,
                        summary: "Upload failed: \(msg)",
                        origin: proposal.origin))
                }
            }
        }
        return try JSONEncoder().encode(AutoAppliedAck.Extra(
            id: remotePath,
            note: "Streaming PUT started app-side. Poll list_vospace_path until the node size is > 0; do not treat a 0-byte node as success."
        ))
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
