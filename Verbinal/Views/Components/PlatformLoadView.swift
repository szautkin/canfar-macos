// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
