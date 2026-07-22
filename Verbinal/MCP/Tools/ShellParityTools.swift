// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Shell parity tools — the last uncovered UI surfaces: opening a
/// VOSpace file straight into the viewer (Storage's "Open in FITS
/// Viewer"), the local file-browser panel, and read-only views of the
/// Endpoints / AI-Compute settings. Capability closures are injected at
/// wiring time.

// MARK: - open_vospace_file

/// Download a VOSpace file and open it in the right viewer (FITS or
/// Cube) — the Storage browser's "Open in FITS Viewer" context action.
struct OpenVOSpaceFileTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let path: String
    }

    struct Payload: Codable, Sendable {
        let path: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "open_vospace_file",
        description: "Download a FITS file from VOSpace (path relative to the user's home, from `list_vospace_path`) and open it in the right viewer — 2D images route to the FITS Viewer, spectral cubes (NAXIS≥3) to the Cube Viewer. The Storage browser's \"Open in FITS Viewer\" action. Downloads to a temporary location; proposal-gated like other VOSpace transfers.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path": { "type": "string", "minLength": 1, "description": "VOSpace file path relative to the user's home." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let path = args.path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            throw ToolFailureReason.invalidArgument("path is empty")
        }
        guard !path.contains("..") else {
            throw ToolFailureReason.invalidArgument("path must not contain '..'")
        }
        return try ProposalPlan.encoding(
            kind: "open_vospace_file",
            summary: "Open VOSpace file in viewer: \(path)",
            payload: Payload(path: path)
        )
    }
}

struct OpenVOSpaceFileApplier: ProposalApplier {
    let kind = "open_vospace_file"
    /// Downloads the file and routes it into the appropriate viewer.
    let openFile: @Sendable (String) async throws -> Void
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(OpenVOSpaceFileTool.Payload.self, from: proposal.payload)
        try await openFile(payload.path)
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}

// MARK: - list_local_folder

/// List a local folder — the file-browser panel's directory view.
struct ListLocalFolderTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        /// Absolute folder path; omit for the user's home directory.
        var path: String?
        /// Only FITS-openable files (the panel's "supported types" filter).
        var supportedOnly: Bool?
    }

    struct Output: Encodable, Sendable {
        let path: String
        let entries: [Entry]
        let truncated: Bool

        struct Entry: Encodable, Sendable {
            let name: String
            let isDirectory: Bool
            let sizeBytes: Int64?
            let isFITS: Bool
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_local_folder",
        description: "List a local folder (absolute `path`; defaults to the user's home) — the file-browser panel's view. Entries carry name, directory flag, size, and whether the file is FITS-openable (`open_local_file`). `supportedOnly: true` mirrors the panel's supported-types filter. Sandboxed locations the app cannot read surface as errors. Capped at 500 entries.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "path":          { "type": "string", "description": "Absolute folder path (default: the user's home)." },
            "supportedOnly": { "type": "boolean", "description": "Only FITS-openable files (directories always listed)." }
          },
          "additionalProperties": false
        }
        """#
    )

    let list: @Sendable (Args) async throws -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        try await list(args)
    }
}

// MARK: - request_folder_access

/// Ask the user to grant the app access to a local folder via the
/// sandbox powerbox picker — the only way to read Pictures/Documents/etc.
/// on macOS. Live-applied (shows a panel); user-mediated.
struct RequestFolderAccessTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        /// Absolute folder to pre-target in the picker (a hint only).
        var startingPath: String?
    }

    struct Output: Encodable, Sendable {
        let granted: Bool
        let path: String?
    }

    enum Result_: Sendable {
        case granted(String)
        case cancelled
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "request_folder_access",
        description: "Open a folder-picker so the USER can grant Verbinal read access to a local folder outside the sandbox default (Pictures, Documents, an external drive…). Needed before `list_local_folder`/`open_local_file` can reach files there — the macOS App Sandbox only grants ~/Downloads and folders the user explicitly picks. `startingPath` pre-targets the picker. Returns `granted:false` if the user cancels. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "startingPath": { "type": "string", "description": "Absolute folder to pre-target in the picker." }
          },
          "additionalProperties": false
        }
        """#
    )

    let request: @Sendable (String?) async -> Result_

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        let body: Output
        switch await request(args.startingPath) {
        case .granted(let path): body = Output(granted: true, path: path)
        case .cancelled: body = Output(granted: false, path: nil)
        }
        do {
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - open_local_file

/// Open a local FITS file in the right viewer — the file-browser
/// panel's file click. Live-applied.
struct OpenLocalFileTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        let path: String
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let path: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "open_local_file",
        description: "Open a local FITS file (absolute path, e.g. from `list_local_folder`) in the right viewer — 2D images route to the FITS Viewer, spectral cubes to the Cube Viewer; the file-browser panel's click. For files the research archive already tracks, prefer `open_fits_file` / `open_cube` by observation id. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path": { "type": "string", "minLength": 1, "description": "Absolute path to a FITS file." }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Returns an error message on failure, or nil when routed to a viewer.
    let open: @Sendable (String) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let message = await open(args.path) {
            return .failed(.invalidArgument(message))
        }
        do {
            let bytes = try JSONEncoder().encode(Output(applied: true, path: args.path))
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - get_endpoints

/// The effective backend endpoints — Settings ▸ Endpoints, read-only.
struct GetEndpointsTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let loginBaseURL: String
        let skahaBaseURL: String
        let acBaseURL: String
        let storageBaseURL: String
        let registryBaseURL: String
        let archiveBaseURL: String
        let externalBaseURL: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_endpoints",
        description: "The EFFECTIVE backend base URLs this app instance talks to (after Settings ▸ Endpoints overrides and IVOA registry resolution): login, Skaha, AC, storage, registry, archive, and external web. Read-only — endpoint changes stay a user decision in Settings. Pair with `get_service_health` to see whether these backends are reachable.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}

// MARK: - get_compute_config

/// The AI-Compute settings that gate `run_code` — read-only, secrets
/// reported only as presence.
struct GetComputeConfigTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let isEnabled: Bool
        let image: String
        let cores: Int
        let ramGB: Int
        let registryHost: String
        let registryUsername: String
        let hasRegistrySecret: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_compute_config",
        description: "The Settings ▸ AI Compute configuration that gates `run_code` / `start_compute`: whether compute is enabled, the container image, default cores/RAM, and the private-registry host/username (the secret itself is never returned — only whether one is stored). Read-only; changing these stays a user decision in Settings.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}
