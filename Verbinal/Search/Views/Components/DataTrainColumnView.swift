// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DataTrainColumnView: View {
    let title: String
    let options: [String]
    let selection: [String]
    let onToggle: (String) -> Void

    @State private var searchText = ""

    private var filteredOptions: [String] {
        if searchText.isEmpty { return options }
        return options.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                if !selection.isEmpty {
                    Text("(\(selection.count))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Filter...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredOptions, id: \.self) { option in
                        Button {
                            onToggle(option)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: selection.contains(option) ? "checkmark.square.fill" : "square")
                                    .font(.caption)
                                    .foregroundColor(selection.contains(option) ? .accentColor : .secondary)
                                Text(option)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 160)
        }
        .frame(width: 130)
    }
}
