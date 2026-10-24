// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// A viewer's file name in the bar, as its menu (the open files, Open…, the
/// file's page), for FITS and Cube alike. Drawn here so a long name truncates
/// in the middle and leaves the bar's buttons — Share, Adjust, ✕ — in it:
/// with a long title, iOS folds them into its overflow rather than shorten
/// the title (seen in the Simulator, plan 49).
struct iOSViewerTitle<Items: View>: View {
    let name: String
    /// The viewer's width: the title takes what the menu button and the
    /// three buttons leave of it.
    let barWidth: CGFloat
    @ViewBuilder var items: () -> Items

    /// Seen on a 402-point iPhone: the menu button ends near 60 points in,
    /// the buttons start near 229 (plan 49).
    private var width: CGFloat { min(max(barWidth - 240, 90), 360) }

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: width)
        }
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityHint(Text("The open files, Open, and the file's page"))
    }
}
