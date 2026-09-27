// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// The clipboard: text, or an observation's details from Search or Research.
extension AppState {
    func makeCopyToClipboardTool() -> CopyToClipboardTool {
        let activity = agentsService.activityStore
        return CopyToClipboardTool(copy: { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                let text: String
                if let given = args.text {
                    text = given
                } else if let pid = args.publisherId?.trimmingCharacters(in: .whitespaces) {
                    let results = self.searchModel.resultsModel
                    guard let row = results.result(publisherID: pid) else {
                        throw ToolFailureReason.unknownTarget("\(pid) is not among the current search results")
                    }
                    text = results.facts(for: row).detailsText
                } else if let id = args.downloadedObservationId {
                    guard let obs = self.researchModel.observationStore.observation(matching: id) else {
                        throw ToolFailureReason.observationNotFound(id: id, localPath: nil)
                    }
                    text = obs.facts.detailsText
                } else {
                    throw ToolFailureReason.invalidArgument("pass text, publisherId or downloadedObservationId")
                }
                let copied = PlatformClipboard.copy(text)
                if copied {
                    activity.append(.live(kind: "copy_to_clipboard", summary: "Copied to the clipboard",
                                          origin: .external(clientID: "copy_to_clipboard")))
                }
                return (text, copied)
            }
        })
    }
}
