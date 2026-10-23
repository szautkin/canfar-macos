// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Compact pasteboard-copy button. Local `@State` flips the icon
/// from `doc.on.doc` to `checkmark.circle.fill` for ~1.5s after a
/// click so the user gets visible feedback without us needing a
/// global toast / overlay. Shared across the failed-row affordance
/// and the modal footer's banner so both surfaces have the same
/// one-click copy behaviour.
struct CopyErrorButton: View {
    let message: String
    @State private var didCopy: Bool = false

    var body: some View {
        Button {
            PlatformClipboard.copy(message)
            didCopy = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(didCopy ? Color.green : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help(didCopy ? "Copied" : "Copy error message to clipboard")
        .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy error to clipboard")
    }
}
