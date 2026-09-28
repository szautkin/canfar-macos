// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// A Portal card's box fills its grid cell — the width of its columns and
/// the height of its row — as on Verbinal for Windows, whose cards stretch
/// to the row. Without it each box is as wide and tall as its contents, so
/// a row's cards come out ragged. The cards themselves know nothing of the
/// grid; the Portal applies this once.
struct PortalCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        GroupBox {
            configuration.content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } label: {
            configuration.label
        }
        // The system's own box, not this style again.
        .groupBoxStyle(.automatic)
    }
}
