// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// A viewer with nothing open: what it is, how to open a file, and the
/// files opened lately — centred in the room there is, and scrolling when
/// the window is shorter than it. It is never taller than its window: the
/// FITS viewer's, pinned to its natural height, pushed the toolbar, the
/// tabs and the activity bar off the window (seen 2026-10-13).
struct ViewerEmptyState<Actions: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let recents: RecentFiles
    let openRecent: (RecentFile) -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(title).font(.title2.bold())
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        actions
                    }
                    RecentFilesList(recents: recents, icon: icon, open: openRecent)
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
