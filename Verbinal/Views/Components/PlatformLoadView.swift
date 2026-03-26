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

struct PlatformLoadView: View {
    @Bindable var model: PlatformLoadModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Platform Load", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.headline)
                    Spacer()

                    if model.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    }

                    Button {
                        Task { await model.loadStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }

                MetricBarView(
                    label: "Available CPU Cores",
                    value: model.cpuAvailable,
                    maxValue: model.cpuTotal,
                    percent: model.cpuPercent,
                    unit: "cores"
                )

                MetricBarView(
                    label: "Available RAM",
                    value: model.ramAvailableGB,
                    maxValue: model.ramTotalGB,
                    percent: model.ramPercent,
                    unit: "GB"
                )

                if model.hasInstanceData {
                    Text(
                        "Instances: \(model.totalInstances) total "
                        + "(\(model.sessionInstances) sessions, "
                        + "\(model.desktopAppInstances) desktop, "
                        + "\(model.headlessInstances) headless)"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if !model.lastUpdate.isEmpty {
                    Text("Last updated: \(model.lastUpdate)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if model.hasError {
                    Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
