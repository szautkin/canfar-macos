// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct HeadlessJobsView: View {
    @Bindable var model: HeadlessMonitorModel

    @State private var showDetail = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    Label("Batch Jobs", systemImage: "gearshape.2")
                        .font(.headline)
                    Spacer()
                    if model.isPolling {
                        Text("\(model.pollCountdown)s")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if model.isLoading && model.jobs.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if model.jobs.isEmpty {
                    Label("No batch jobs", systemImage: "tray")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    // Summary counts only — clickable to open detail modal
                    Button { showDetail = true } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            summaryRow
                            Text("\(model.jobs.count) total")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if model.hasError {
                    Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .sheet(isPresented: $showDetail) {
            HeadlessJobsDetailSheet(model: model)
        }
    }

    // MARK: - Summary

    private var summaryRow: some View {
        HStack(spacing: 10) {
            if model.runningCount > 0 {
                statusPill(count: model.runningCount, label: "running", color: .green)
            }
            if model.pendingCount > 0 {
                statusPill(count: model.pendingCount, label: "pending", color: .orange)
            }
            if model.completedCount > 0 {
                statusPill(count: model.completedCount, label: "done", color: .blue)
            }
            if model.failedCount > 0 {
                statusPill(count: model.failedCount, label: "failed", color: .red)
            }
        }
    }

    private func statusPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
