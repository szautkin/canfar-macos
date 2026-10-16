// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// An image tool that says when package lists are still coming from the
/// person's storage (plan 40): on a new device the first sync brings about
/// three hundred, and until it has, an image missing a package may only be
/// missing its list. Its answer gains `arriving`; a "not probed" failure,
/// the same words. One wrapper for the four tools that read the lists.
struct ArrivingNoteTool<Wrapped: AITool>: AITool {
    static var verbClass: VerbClass { Wrapped.verbClass }
    static var agentSafe: Bool { Wrapped.agentSafe }

    let wrapped: Wrapped
    /// The words, while lists are still coming or paused; nil otherwise.
    let note: @Sendable () async -> String?

    var definition: AIToolDefinition { wrapped.definition }

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let result = await wrapped.invoke(arguments: arguments, context: context)
        guard let words = await note() else { return result }
        switch result {
        case .data(let data):
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return result }
            object["arriving"] = words
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { .data($0) } ?? result
        case .failed(.unknownTarget(let why)):
            return .failed(.unknownTarget("\(why). \(words)"))
        default:
            return result
        }
    }
}
