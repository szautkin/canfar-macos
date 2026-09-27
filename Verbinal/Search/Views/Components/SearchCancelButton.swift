// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Cancel beside the spinner while a search runs — on the form and in the
/// ADQL editor alike. The rows already shown stay.
struct SearchCancelButton: View {
    let searchModel: SearchFormModel

    var body: some View {
        if searchModel.isSearching {
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
