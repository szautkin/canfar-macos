// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct MetricBarView: View {
    let label: String
    let value: Double
    let maxValue: Double
    let percent: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(String(format: "%.1f / %.1f %@ (%.0f%%)", value, maxValue, unit, percent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(percent, 100), total: 100)
                .tint(percent > 90 ? .red : percent > 70 ? .orange : .accentColor)
        }
    }
}
