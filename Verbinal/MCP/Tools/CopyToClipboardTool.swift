// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Put text — or an observation's details, exactly as Copy Details writes
/// them — on the user's clipboard.
struct CopyToClipboardTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        var text: String?
        var publisherId: String?
        var downloadedObservationId: String?
    }

    struct Output: Encodable, Sendable {
        let copied: Bool
        let text: String
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "copy_to_clipboard",
        description: "Put text on the user's clipboard — pass `text` — or an observation's details, the same text Copy Details copies (ID, collection, publisher ID, target, position in sexagesimal with the degrees beside it, instrument, filter, date, calibration level, proposal, release): pass `publisherId` for a row of the current search results, or `downloadedObservationId` for one in Research. Exactly one of the three. `copied: false` means the clipboard refused it. Live-applied; no proposal.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "text": { "type": "string" },
            "publisherId": { "type": "string" },
            "downloadedObservationId": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Resolves the text for the arguments (throwing why not) and copies it;
    /// returns the text and whether the clipboard took it.
    let copy: @Sendable (Args) async throws -> (text: String, copied: Bool)

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments.isEmpty ? Data("{}".utf8) : arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        let given = [args.text, args.publisherId, args.downloadedObservationId].compactMap { $0 }
        guard given.count == 1 else {
            return .failed(.invalidArgument("pass exactly one of text, publisherId, downloadedObservationId"))
        }
        do {
            let result = try await copy(args)
            return .data(try JSONEncoder().encode(Output(copied: result.copied, text: result.text)))
        } catch let failure as ToolFailureReason {
            return .failed(failure)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
