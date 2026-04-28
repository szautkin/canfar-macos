// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// Displays all FITS header cards for the selected HDU with search filtering.
struct FITSHeaderPanel: View {
    var model: FITSViewerModel
    @State private var filterText = ""

    private var filteredCards: [FITSCard] {
        guard let hdu = model.selectedHDU else { return [] }
        let cards = hdu.header.orderedCards
        guard !filterText.isEmpty else { return cards }
        let query = filterText.lowercased()
        return cards.filter {
            $0.keyword.lowercased().contains(query) ||
            $0.value.lowercased().contains(query) ||
            $0.comment.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Header")
                    .font(.caption.bold())
                Spacer()
                Text("\(filteredCards.count) cards")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)

            TextField("Filter keywords...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
                .padding(.horizontal, 8)

            List(Array(filteredCards.enumerated()), id: \.offset) { _, card in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(card.keyword)
                            .font(.system(.caption2, design: .monospaced).bold())
                            .frame(width: 70, alignment: .leading)
                        Text("=")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(card.value)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if !card.comment.isEmpty {
                        Text("/ \(card.comment)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
