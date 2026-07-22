// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// House style for inline panel/form errors: one warning glyph, a bounded
/// two-line message, and a copy affordance for the full text.
///
/// Before this existed every dashboard panel dumped `model.errorMessage`
/// (raw backend/HTTP text) into an unbounded `Label` with its own choice
/// of glyph — a long Skaha 500 body could blow out the panel, the full
/// text was unrecoverable once truncated elsewhere, and sibling panels
/// disagreed on iconography. The discovery sheets set the house pattern
/// (wrapped message + `CopyErrorButton`); this component makes it the
/// one-line default everywhere.
struct InlineErrorLabel: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
            Text(message)
                .lineLimit(2)
                .truncationMode(.tail)
            CopyErrorButton(message: message)
        }
        .font(.caption)
        .foregroundStyle(.red)
    }
}
