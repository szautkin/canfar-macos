// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - get_platform_load

/// Report platform-wide load on the CANFAR Science Platform: CPU cores
/// and RAM requested vs available, plus how many instances are running
/// by type. Read-only; the wiring closure fetches from Skaha.
struct GetPlatformLoadTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let instances: Instances?
        let cores: Cores?
        let ram: Ram?

        struct Instances: Encodable, Sendable {
            let session: Int?
            let desktopApp: Int?
            let headless: Int?
            let total: Int?
        }

        struct Cores: Encodable, Sendable {
            let requested: Double
            let available: Double
        }

        struct Ram: Encodable, Sendable {
            let requestedGB: Double?
            let availableGB: Double?
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_platform_load",
        description: "CANFAR platform load — CPU cores and RAM requested vs available, plus running instance counts (session / desktopApp / headless / total). Use this to judge whether the platform has room before launching sessions or headless jobs.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable () async throws -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        try await fetch()
    }
}

// MARK: - get_storage_quota

/// Report the signed-in user's VOSpace storage usage against quota.
struct GetStorageQuotaTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let usedBytes: Int64
        let quotaBytes: Int64
        let usedGB: Double
        let quotaGB: Double
        let usagePercent: Double
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_storage_quota",
        description: "The signed-in user's VOSpace storage usage vs quota (bytes, GB, and percent used). Requires sign-in — fails with authRequired when the user is signed out.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    /// Throws `ToolFailureReason.authRequired` when the user is signed
    /// out; the wiring closure supplies that check.
    let fetch: @Sendable () async throws -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        try await fetch()
    }
}
