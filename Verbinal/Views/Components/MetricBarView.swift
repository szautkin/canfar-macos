// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct MetricBarView: View {
    /// `LocalizedStringKey` so call-site literals route through the catalog.
    let label: LocalizedStringKey
    let value: Double
    let maxValue: Double
    let percent: Double
    /// Localized at the call site (e.g. `String(localized: "cores")`).
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                // Locale-aware numbers; the surrounding pattern is a catalog
                // key so translators can reorder it.
                Text("\(value.formatted(.number.precision(.fractionLength(1)))) / \(maxValue.formatted(.number.precision(.fractionLength(1)))) \(unit) (\((percent / 100).formatted(.percent.precision(.fractionLength(0)))))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(percent, 100), total: 100)
                .tint(percent > 90 ? .red : percent > 70 ? .orange : .accentColor)
                // Ease the bar from old→new on each poll instead of jumping.
                .appAnimation(AppMotion.quick, value: percent)
        }
    }
}
