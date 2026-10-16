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

                    if model.load.isWorking {
                        ProgressView()
                            .scaleEffect(0.6)
                    }

                    Button {
                        Task { await model.loadStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh cluster load statistics")
                    .accessibilityLabel("Refresh platform stats")
                }

                // Three rings in a row; a card too narrow for that puts the
                // GPU's under the other two (plan 41).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { cpu; ram; gpu }
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) { cpu; ram }
                        gpu
                    }
                }
                .frame(maxWidth: .infinity)

                if model.hasInstanceData {
                    // One interpolated literal (not concatenation) so the whole
                    // sentence lands in the string catalog as a single key.
                    Text("Instances: \(model.totalInstances) total (\(model.sessionInstances) sessions, \(model.desktopAppInstances) desktop, \(model.headlessInstances) headless)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !model.lastUpdate.isEmpty {
                    Text("Last updated: \(model.lastUpdate)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if model.load.problem != nil {
                    ProblemView(problem: model.load.problem, retry: { Task { await model.loadStats() } }, compact: true)
                }
            }
        }
    }

    private var cpu: some View {
        LoadDonutView(title: "CPU", spokenTitle: "CPU load", load: model.cpu,
                      freeUnit: String(localized: "cores free"),
                      missing: "The platform's statistics have no CPU numbers", id: "portal.load.cpu", known: model.load.value != nil)
    }

    private var ram: some View {
        LoadDonutView(title: "RAM", spokenTitle: "RAM load", load: model.ram,
                      freeUnit: String(localized: "GB free"),
                      missing: "The platform's statistics have no RAM numbers", id: "portal.load.ram", known: model.load.value != nil)
    }

    private var gpu: some View {
        LoadDonutView(title: "GPU", spokenTitle: "GPU load", load: model.gpu,
                      freeUnit: String(localized: "GPUs free"),
                      missing: "This platform does not report GPUs yet", id: "portal.load.gpu", known: model.load.value != nil)
    }
}
