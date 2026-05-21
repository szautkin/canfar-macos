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
        description: "Upload a downloaded observation's local file to a VOSpace path. Use `upload_text_to_vospace` instead if your source is in-conversation text (script, config, JSON) rather than a downloaded file. Synchronous with a 10-min applier deadline; a stuck transfer surfaces as `backendError` with the deadline named, not a silent hang. For files > ~100 MB on slow links: the underlying transfer can outlast the MCP transport timeout — on `Request timed out`, re-poll `list_vospace_path` after 30–60s, the bytes are often there.",
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

// MARK: - upload_text_to_vospace

/// Upload an arbitrary text blob (script, JSON config, notebook
/// payload) to a VOSpace path. The companion of `upload_to_vospace`
/// for cases where the source is in-conversation content rather
/// than a previously-downloaded observation — closes the gap that
/// forced inline-script-in-env, which itself ran into the Skaha
/// quirks the headless validator now catches.
///
/// Size cap is 1 MB — large enough for any reasonable script,
/// small enough that the synchronous upload completes well
/// inside the MCP transport window and the watchdog deadline.
/// For anything larger, download locally and re-upload via the
/// observation path.
struct UploadTextToVOSpaceTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let vospace_path: String
        let content: String
    }

    struct Payload: Codable, Sendable {
        let vospacePath: String
        let content: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "upload_text_to_vospace",
        description: "Upload an arbitrary text blob (Python script, JSON config, notebook fragment) to a VOSpace path. Body is the literal text — no encoding tricks needed. Size cap 1 MB. Use this to stage code or config that a headless job will later pull from VOSpace, e.g. `python3 /arc/projects/foo/script.py` inside the container. Synchronous; completes in well under a second for typical script sizes.",
        schema: #"""
        {
          "type": "object",
          "required": ["vospace_path", "content"],
          "properties": {
            "vospace_path": { "type": "string", "description": "Target VOSpace path including the destination filename, no leading slash." },
            "content":      { "type": "string", "description": "The text to write. UTF-8." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.vospace_path.isEmpty else {
            throw ToolFailureReason.invalidArgument("vospace_path is empty")
        }
        let byteSize = args.content.utf8.count
        let cap = 1024 * 1024
        guard byteSize <= cap else {
            throw ToolFailureReason.invalidArgument(
                "content is \(byteSize) bytes; upload_text_to_vospace caps at \(cap) bytes (1 MB). For larger payloads, write locally and re-upload via upload_to_vospace."
            )
        }
        return try ProposalPlan.encoding(
            kind: "upload_text_to_vospace",
            summary: "Upload \(byteSize)-byte text to VOSpace: \(args.vospace_path)",
            payload: Payload(vospacePath: args.vospace_path, content: args.content)
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
        description: "Download a VOSpace file to the user's Downloads folder. Synchronous with a 10-min applier deadline; a stuck transfer surfaces as `backendError` with the deadline named, not a silent hang. For files > ~100 MB on slow links: the underlying transfer can outlast the MCP transport timeout — on `Request timed out` re-check the Downloads folder before retrying, the bytes are often there.",
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
        var recursive: Bool?
    }

    struct Payload: Codable, Sendable {
        let path: String
        let recursive: Bool
    }

    /// Hard cap on nodes touched in a single recursive delete.
    /// 2026-05-15 QA report explicitly named recursive cleanup
    /// of `__pycache__` (3 calls for one logical action) as a
    /// pain point; 100 is enough for that and most other
    /// realistic cleanups, while still bounding catastrophic
    /// misclicks ("delete my whole home").
    static let recursiveDeleteCap: Int = 100

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_vospace_node",
        description: "Permanently delete a VOSpace node (file or folder). Pass `recursive: true` to delete a folder and everything under it in one call — without it, deleting a non-empty folder fails because the VOSpace server requires the container to be empty. The 2026-05-15 QA report flagged this: cleaning `__pycache__` took three calls (list → delete leaves → delete dir) instead of one. Recursive walk is post-order and capped at 100 nodes per call as a safety bound; for larger trees, split into multiple invocations. Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation in the strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path":      { "type": "string", "minLength": 1 },
            "recursive": { "type": "boolean", "description": "Delete a folder and all its descendants. Capped at 100 nodes per call." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.path.isEmpty else {
            throw ToolFailureReason.invalidArgument("path is empty")
        }
        let recursive = args.recursive ?? false
        let summary = recursive
            ? "Recursively delete from VOSpace: \(args.path)/ (and everything beneath, up to \(Self.recursiveDeleteCap) nodes)"
            : "Delete from VOSpace: \(args.path)"
        return try ProposalPlan.encoding(
            kind: "delete_vospace_node",
            summary: summary,
            payload: Payload(path: args.path, recursive: recursive)
        )
    }
}

// MARK: - clear_user_site (destructive)

/// Wipe the user's `~/.local/lib/python3.*/site-packages`
/// directories in VOSpace. Closes the
/// "pip --user poisons subsequent jobs" recurring friction
/// the 2026-05-14 QA review flagged — a single `pip install
/// --user` in a notebook can replace numpy with an
/// incompatible major version, breaking pandas/erfa in every
/// later headless run until the user-site is cleared.
///
/// Doesn't touch `~/.local/bin` or `~/.local/share` (user
/// might have legitimate binaries / docs there) and doesn't
/// touch the system-site or conda-managed envs inside the
/// container — only the per-user pip-installed packages on
/// the persistent VOSpace overlay.
struct ClearUserSiteTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    typealias Args = EmptyArgs
    struct Payload: Codable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_user_site",
        description: "Wipe the user's ~/.local/lib/python3.*/site-packages directories in VOSpace. Use when `pip install --user` has poisoned subsequent jobs with incompatible package versions (typical symptom: `numpy` got upgraded across a major version boundary and pandas/erfa/scipy now error out). Doesn't touch ~/.local/bin or ~/.local/share. Doesn't touch system-site or conda envs (those live inside the container image, not in VOSpace). Destructive — runs immediately under auto-apply.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: EmptyArgs, context: AIToolContext) async throws -> ProposalPlan {
        try ProposalPlan.encoding(
            kind: "clear_user_site",
            summary: "Wipe user-site Python packages from VOSpace (~/.local/lib/python3.*/site-packages)",
            payload: Payload()
        )
    }
}

struct ClearUserSiteApplier: ProposalApplier {
    let kind = "clear_user_site"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let service = context.service
        let username = await context.username()
        guard !username.isEmpty else {
            throw ProposalApplyError.backendError("not authenticated")
        }

        // Two VOSpace round-trips: enumerate the python3.X dirs
        // under .local/lib, then drop site-packages for each.
        // VOSpace deletes are recursive by default, so a single
        // DELETE per python version cleans the whole subtree.
        // Wrapped in withApplierTimeout to bound the rare case
        // where the recursive delete walks a multi-thousand-
        // file tree under load.
        try await withApplierTimeout(seconds: 300, label: "clear_user_site") {
            let pythonDirs: [VOSpaceNode]
            do {
                pythonDirs = try await service.listNodes(
                    username: username,
                    path: ".local/lib"
                )
            } catch {
                // No `.local/lib` at all is the success case —
                // there's nothing to clear and the user's
                // problem (if any) is somewhere else.
                return
            }
            for dir in pythonDirs where dir.name.hasPrefix("python") {
                let target = ".local/lib/\(dir.name)/site-packages"
                // Best-effort: a missing site-packages under a
                // given python version is fine, just skip it.
                _ = try? await service.deleteNode(
                    username: username,
                    path: target
                )
            }
        }

        let activity = context.activity
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: "clear_user_site"))
        }
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

extension VOSpaceAppliers {
    /// Standard applier flow: decode the payload, check that a
    /// username is available, run the supplied service call, and
    /// emit the terminal `.applied` activity event. Centralised
    /// because every VOSpace applier — and most appliers in the
    /// app — repeat this exact prologue/epilogue; concentrating
    /// it in one place keeps the per-call site focused on the
    /// service method that actually matters.
    ///
    /// `timeout`, when non-nil, wraps `work` in
    /// `withApplierTimeout(...)` so a hang inside the service
    /// always surfaces as `proposalRejected` instead of an
    /// invisible silent stall (F-2026-05-13-A).
    func runAuthenticated<P: Decodable & Sendable>(
        _ proposal: PendingProposal,
        kind: String,
        payloadType: P.Type,
        operationLabel: String,
        timeout: TimeInterval? = nil,
        _ work: @escaping @Sendable (String, P) async throws -> Void
    ) async throws {
        let payload = try JSONDecoder().decode(P.self, from: proposal.payload)
        let username = await self.username()
        guard !username.isEmpty else {
            throw ProposalApplyError.backendError("not authenticated")
        }
        do {
            if let timeout {
                try await withApplierTimeout(seconds: timeout, label: kind) {
                    try await work(username, payload)
                }
            } else {
                try await work(username, payload)
            }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("\(operationLabel) failed: \(error.localizedDescription)")
        }
        let activity = self.activity
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
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
            // 10-minute wall-clock deadline. Bounds the worst-case
            // hang (URLSession stuck after body without a server
            // response, sandbox file-coordination deadlock) so the
            // applier always emits a terminal lifecycle event —
            // closes F-2026-05-13-A from the QA log.
            let service = context.service
            let remotePath = payload.vospacePath
            try await withApplierTimeout(seconds: 600, label: "upload_to_vospace") {
                try await service.uploadFile(username: username, remotePath: remotePath, fileURL: url)
            }
        } catch let pa as ProposalApplyError {
            // Preserve the timeout's typed message; only wrap
            // genuinely-foreign errors below.
            throw pa
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
            // 10-minute deadline — same rationale as upload above.
            let service = context.service
            let path = payload.vospacePath
            result = try await withApplierTimeout(seconds: 600, label: "download_from_vospace") {
                try await service.downloadFile(username: username, path: path)
            }
        } catch let pa as ProposalApplyError {
            throw pa
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

struct UploadTextToVOSpaceApplier: ProposalApplier {
    let kind = "upload_text_to_vospace"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let service = context.service
        try await context.runAuthenticated(
            proposal,
            kind: kind,
            payloadType: UploadTextToVOSpaceTool.Payload.self,
            operationLabel: "upload_text",
            // 2-minute deadline. Text uploads are tiny by design
            // (1 MB cap in `plan`); anything beyond that is
            // backend stall, not a legitimate slow transfer.
            // Same watchdog primitive as the file-upload path —
            // F-2026-05-13-A no-terminal-event protection.
            timeout: 120
        ) { username, payload in
            // Stage to a temp file on disk so we can reuse
            // VOSpaceBrowserService.uploadFile's stream-from-disk
            // path (which the security-scoped/sandbox plumbing
            // depends on). Write atomically: contents land at
            // .partial first, then rename, so a crash mid-write
            // doesn't leave a half-written file the next call
            // would mistake for the source.
            let tempDir = FileManager.default.temporaryDirectory
            let stagingURL = tempDir.appendingPathComponent("verbinal-upload-\(UUID().uuidString).txt")
            guard let data = payload.content.data(using: .utf8) else {
                throw ProposalApplyError.backendError("could not encode content as UTF-8")
            }
            do {
                try data.write(to: stagingURL, options: .atomic)
            } catch {
                throw ProposalApplyError.backendError("could not stage upload to temp file: \(error.localizedDescription)")
            }
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            try await service.uploadFile(
                username: username,
                remotePath: payload.vospacePath,
                fileURL: stagingURL
            )
        }
    }
}

struct VOSpaceMkdirApplier: ProposalApplier {
    let kind = "vospace_mkdir"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let service = context.service
        try await context.runAuthenticated(
            proposal,
            kind: kind,
            payloadType: VOSpaceMkdirTool.Payload.self,
            operationLabel: "mkdir",
            // 60-second deadline. Folder creation is a single PUT
            // with a tiny XML body; anything longer than ~30s is
            // backend trouble, not a slow upload.
            timeout: 60
        ) { username, payload in
            try await service.createFolder(
                username: username,
                parentPath: payload.parentPath,
                folderName: payload.folderName
            )
        }
    }
}

struct DeleteVOSpaceNodeApplier: ProposalApplier {
    let kind = "delete_vospace_node"
    fileprivate let context: VOSpaceAppliers

    func apply(_ proposal: PendingProposal) async throws {
        let service = context.service
        // Recursive deletes hit one HTTP request per descendant
        // plus one listing call per intermediate folder; a
        // realistic cleanup of ~50 leaves easily takes 30-60s on
        // a sleepy VOSpace, so the watchdog needs more headroom
        // than the single-node path's 60s.
        let timeout: TimeInterval = 300
        let cap = DeleteVOSpaceNodeTool.recursiveDeleteCap
        try await context.runAuthenticated(
            proposal,
            kind: kind,
            payloadType: DeleteVOSpaceNodeTool.Payload.self,
            operationLabel: "delete",
            timeout: timeout
        ) { username, payload in
            if payload.recursive {
                _ = try await Self.deleteRecursive(
                    username: username,
                    path: payload.path,
                    service: service,
                    runningCount: 0,
                    cap: cap
                )
            } else {
                try await service.deleteNode(username: username, path: payload.path)
            }
        }
    }

    /// Post-order recursive delete. Descends through every
    /// container child first (so the parent is empty when its
    /// turn comes — VOSpace's DELETE refuses non-empty
    /// containers), then deletes the current node.
    ///
    /// `listNodes` failure is treated as "this is a leaf"; the
    /// subsequent `deleteNode` either succeeds (it's a file) or
    /// surfaces the real reason. Avoids an extra round-trip per
    /// file just to learn the type.
    ///
    /// Throws when the cumulative count crosses `cap`, naming
    /// how many were already removed so the caller can decide
    /// whether to retry (the deleted ones don't come back).
    private static func deleteRecursive(
        username: String,
        path: String,
        service: VOSpaceBrowserService,
        runningCount: Int,
        cap: Int
    ) async throws -> Int {
        var count = runningCount
        let children: [VOSpaceNode] = (try? await service.listNodes(
            username: username, path: path, limit: 500
        )) ?? []
        for child in children {
            count = try await deleteRecursive(
                username: username,
                path: child.path,
                service: service,
                runningCount: count,
                cap: cap
            )
        }
        try await service.deleteNode(username: username, path: path)
        count += 1
        if count > cap {
            throw ProposalApplyError.backendError(
                "Recursive delete cap (\(cap)) exceeded after deleting '\(path)' — \(count) nodes removed in total. The cap is a safety bound against runaway deletes; retry with the same path to continue, or break the deletion into smaller subtrees."
            )
        }
        return count
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
        UploadTextToVOSpaceApplier(context: context),
        DownloadFromVOSpaceApplier(context: context),
        VOSpaceMkdirApplier(context: context),
        DeleteVOSpaceNodeApplier(context: context),
        ClearUserSiteApplier(context: context),
    ]
}
