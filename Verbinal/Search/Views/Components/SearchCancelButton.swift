// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Cancel beside the spinner while a search runs — on the form and in the
/// ADQL editor alike — and, once it has waited a while, how long: a search
/// on an archive that is down was a spinner and nothing else (plan 21 D5).
/// The rows already shown stay.
struct SearchCancelButton: View {
    let searchModel: SearchFormModel

    /// Seconds before the wait is shown: most searches are done by then.
    static let showWaitAfter: TimeInterval = 10

    var body: some View {
        if searchModel.isSearching {
            if let started = searchModel.searchStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let waited = Int(context.date.timeIntervalSince(started))
                    if Double(waited) >= Self.showWaitAfter {
                        Text("Waiting for CADC — \(waited) s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                searchModel.cancelSearch()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .help("Stop the running search")
        }
    }
}
