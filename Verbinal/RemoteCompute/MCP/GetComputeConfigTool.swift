// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

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
