// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Reports whether the human user is logged into CADC. Agents should
/// gate any tool that requires authenticated CADC access on the result
/// of this call.
struct GetAuthStateTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let isAuthenticated: Bool
        let username: String
        let displayName: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_auth_state",
        description: "Returns whether the user is currently authenticated to CADC and their displayName.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    /// Read snapshot taken once per call from a `@MainActor` source so
    /// the bridge actor doesn't reach into AppState directly.
    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}
