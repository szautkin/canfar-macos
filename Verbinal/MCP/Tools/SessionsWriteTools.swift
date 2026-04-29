// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - launch_session

/// Launch a Skaha session. Always proposal-gated — sessions consume
/// real cores/RAM/GPU resources and the proposal strip's confirmation
/// is the user's only safety against an agent typo.
struct LaunchSessionTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let type: String
        let name: String
        let image: String
        var cores: Int?
        var ram: Int?
        var gpus: Int?
        var cmd: String?
    }

    struct Payload: Codable, Sendable {
        let type: String
        let name: String
        let image: String
        let cores: Int
        let ram: Int
        let gpus: Int
        let cmd: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "launch_session",
        description: "Launch a new Skaha science-platform session. Type ∈ {notebook, desktop, firefly, carta, contributed}. cores/ram/gpus default to 2/8/0 if omitted.",
        schema: #"""
        {
          "type": "object",
          "required": ["type", "name", "image"],
          "properties": {
            "type":  { "type": "string", "enum": ["notebook", "desktop", "firefly", "carta", "contributed"] },
            "name":  { "type": "string", "minLength": 1 },
            "image": { "type": "string", "minLength": 1 },
            "cores": { "type": "integer", "minimum": 1 },
            "ram":   { "type": "integer", "minimum": 1 },
            "gpus":  { "type": "integer", "minimum": 0 },
            "cmd":   { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let cores = args.cores ?? 2
        let ram = args.ram ?? 8
        let gpus = args.gpus ?? 0
        let summary = "Launch \(args.type) '\(args.name)' (\(cores) cores, \(ram) GB" +
                      (gpus > 0 ? ", \(gpus) GPUs" : "") +
                      ") — image: \(args.image)"
        return try ProposalPlan.encoding(
            kind: "launch_session",
            summary: summary,
            payload: Payload(
                type: args.type, name: args.name, image: args.image,
                cores: cores, ram: ram, gpus: gpus, cmd: args.cmd
            )
        )
    }
}

struct LaunchSessionApplier: ProposalApplier {
    let kind = "launch_session"
    let service: SessionService

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(LaunchSessionTool.Payload.self, from: proposal.payload)
        let params = SessionLaunchParams(
            type: payload.type, name: payload.name, image: payload.image,
            cores: payload.cores, ram: payload.ram, gpus: payload.gpus,
            cmd: payload.cmd, registryUsername: nil, registrySecret: nil
        )
        do {
            _ = try await service.launchSession(params)
        } catch {
            throw ProposalApplyError.backendError("launch failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - delete_session (destructive)

struct DeleteSessionTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let id: String
    }

    struct Payload: Codable, Sendable {
        let id: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_session",
        description: "Terminate a running Skaha session. Destructive — user must confirm in strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.id.isEmpty else {
            throw ToolFailureReason.invalidArgument("id is empty")
        }
        return try ProposalPlan.encoding(
            kind: "delete_session",
            summary: "Terminate session \(args.id)",
            payload: Payload(id: args.id)
        )
    }
}

struct DeleteSessionApplier: ProposalApplier {
    let kind = "delete_session"
    let service: SessionService

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DeleteSessionTool.Payload.self, from: proposal.payload)
        do {
            try await service.deleteSession(id: payload.id)
        } catch {
            throw ProposalApplyError.backendError("delete failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - clear_research_archive (destructive)

/// Wipe all locally-stored downloaded observation metadata. Doesn't
/// touch local files — the user keeps the downloads on disk; only the
/// archive index is cleared.
struct ClearResearchArchiveTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    typealias Args = EmptyArgs

    struct Payload: Codable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "clear_research_archive",
        description: "Remove ALL downloaded-observation metadata records. Does not touch local files. Destructive — user confirms in strip.",
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
            kind: "clear_research_archive",
            summary: "Clear ALL research archive records",
            payload: Payload()
        )
    }
}

struct ClearResearchArchiveApplier: ProposalApplier {
    let kind = "clear_research_archive"
    let store: ObservationStore

    func apply(_ proposal: PendingProposal) async throws {
        await MainActor.run { store.clear() }
    }
}
