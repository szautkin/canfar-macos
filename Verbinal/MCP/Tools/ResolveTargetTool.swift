// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Resolve a target name to coordinates via the CADC name resolver.
///
/// Service is "all" by default (consults SIMBAD, NED, and VizieR in turn);
/// agents can pin to a specific resolver for repeatability.
struct ResolveTargetTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let name: String
        var service: String?
    }

    struct Output: Encodable, Sendable {
        let target: String
        let service: String
        let raDeg: Double?
        let decDeg: Double?
        let raString: String
        let decString: String
        let coordsys: String?
        let objectType: String?
        let morphologyType: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "resolve_target",
        description: "Look up a target name (e.g. 'M31', 'NGC 1234', 'HD 209458') and return its coordinates plus type/morphology. Service defaults to 'all'.",
        schema: #"""
        {
          "type": "object",
          "required": ["name"],
          "properties": {
            "name":    { "type": "string" },
            "service": { "type": "string", "enum": ["all", "simbad", "ned", "vizier"] }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Closure that runs the resolver and returns a flat output the tool
    /// can encode without owning the service type.
    let resolve: @Sendable (_ name: String, _ service: String) async throws -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let svc = args.service ?? "all"
        return try await resolve(args.name, svc)
    }
}
