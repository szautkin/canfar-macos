// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
