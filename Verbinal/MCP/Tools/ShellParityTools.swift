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
        description: "Download a FITS file from VOSpace (path relative to the user's home, from `list_vospace_path`) and open it in the right viewer — 2D images route to the FITS Viewer; NAXIS≥3 files show the Open as… sheet (`get_current_view.pendingViewerChoice`) and this ack's `note` tells you to call `choose_viewer`. The Storage browser's \"Open in FITS Viewer\" action. Downloads to a temporary location; proposal-gated like other VOSpace transfers.",
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

struct OpenVOSpaceFileApplier: ProposalApplier, ResultReportingApplier {
    let kind = "open_vospace_file"
    /// Downloads the file and routes it into the appropriate viewer.
    /// Returns an agent note when the Open as… sheet is showing.
    let openFile: @Sendable (String) async throws -> String?
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(OpenVOSpaceFileTool.Payload.self, from: proposal.payload)
        let note = try await openFile(payload.path)
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        let extra = AutoAppliedAck.Extra(note: note)
        return (try? JSONEncoder().encode(extra)) ?? Data()
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
        description: "List a local folder the app can read. Omit `path` to list the user's Downloads (`/Users/<name>/Downloads` — the same path `list_open_tabs` reports). Only ~/Downloads and folders granted via `request_folder_access` (or the Storage file browser) are readable. Unreadable paths return typed `notReadable`. `supportedOnly: true` lists FITS-openable files (directories always listed). Capped at 500 entries.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "path":          { "type": "string", "description": "Absolute folder path (default: the user's Downloads)." },
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
        /// Guidance when the grant did not happen (non-interactive agent, cancel).
        let note: String?
    }

    enum Result_: Sendable {
        case granted(String)
        case cancelled
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "request_folder_access",
        description: "Ask the USER to grant Verbinal read access to a local folder outside the sandbox default (Pictures, Documents, an external drive…). Needed before `list_local_folder`/`open_local_file` can reach files there — the macOS App Sandbox only grants ~/Downloads and folders the user explicitly picks. MCP clients cannot show the macOS folder picker: from an agent this returns `granted: false` immediately with guidance to grant the folder in Storage. In the in-app AI Guide, `startingPath` pre-targets the picker. Live-applied; no proposal.",
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
        if case .external = context.origin {
            let body = Output(
                granted: false,
                path: nil,
                note: "MCP clients cannot show the macOS folder picker. Ask the user to grant the folder in Storage (file browser ▸ Grant Access), then retry list_local_folder / open_local_file."
            )
            do {
                let bytes = try JSONEncoder().encode(body)
                return .data(bytes)
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
        let body: Output
        switch await request(args.startingPath) {
        case .granted(let path): body = Output(granted: true, path: path, note: nil)
        case .cancelled: body = Output(
            granted: false, path: nil,
            note: "The user cancelled the folder picker.")
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
        /// Skip the Open as… sheet: `"fits"` or `"cube"`.
        let viewer: String?
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let path: String
        /// `"fits"` or `"cube"` when the file is already open; nil when
        /// the Open as… sheet is waiting (`pendingViewerChoice` true).
        let viewer: String?
        let pendingViewerChoice: Bool
        let note: String?
        /// Still loading when the wait ran out — large, not failed.
        var stillLoading = false
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "open_local_file",
        description: "Open a local FITS file (absolute path, e.g. from `list_local_folder`) in the right viewer. A very large file still loading after ~40 s answers `stillLoading: true` — do not open it again; a file already open switches to its tab. 2D images go to the FITS Viewer. NAXIS≥3 files show the same Open as… sheet the UI uses — this call then returns `pendingViewerChoice: true` and you must call `choose_viewer` (fits / cube / dismiss). Pass `viewer` ('fits' or 'cube') to skip the sheet. For files the research archive already tracks, prefer `open_fits_file` / `open_cube` by observation id. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "required": ["path"],
          "properties": {
            "path": { "type": "string", "minLength": 1, "description": "Absolute path to a FITS file." },
            "viewer": {
              "type": "string",
              "enum": ["fits", "cube"],
              "description": "Skip the Open as… sheet and open in this viewer. Omit to detect NAXIS≥3 and prompt via choose_viewer."
            }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Throws `ToolFailureReason` on failure.
    let open: @Sendable (_ path: String, _ viewer: String?) async throws -> Output

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        let viewer = args.viewer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let viewer, !["fits", "cube"].contains(viewer) {
            return .failed(.invalidArgument("viewer must be 'fits' or 'cube'"))
        }
        do {
            let body = try await open(args.path, viewer)
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch let f as ToolFailureReason {
            return .failed(f)
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
