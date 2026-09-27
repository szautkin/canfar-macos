// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// One choice among a few, as a row of capsules — every option in sight,
/// where a menu hides them. Scrolls sideways when the row is too long.
struct ChipRow<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.value) { option in
                    let chosen = option.value == selection
                    Button { selection = option.value } label: {
                        Text(option.title)
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(chosen ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(chosen ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
    }
}
