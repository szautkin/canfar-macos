// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// "Recently opened", as a viewer's empty screen offers it.
struct RecentFilesList: View {
    var recents: RecentFiles
    /// The icon beside each file — the viewer's own.
    var icon: String
    var open: (RecentFile) -> Void

    var body: some View {
        if !recents.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENTLY OPENED").font(.caption2.bold()).tracking(1.5).foregroundStyle(.secondary)
                ForEach(recents.items) { recent in
                    Button { open(recent) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon).foregroundStyle(.secondary)
                            Text(recent.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .help(recent.path)
                    .accessibilityLabel(Text(recent.name))
                    .accessibilityHint(Text("Opens it again"))
                }
            }
            .frame(maxWidth: 420)
        }
    }
}
