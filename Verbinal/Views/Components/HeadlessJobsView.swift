// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct HeadlessJobsView: View {
    @Bindable var model: HeadlessMonitorModel


    /// Boundary discriminator for the cross-fade. Maps the model's load/empty
    /// flags onto `DataState`; `.error` is unused here because the error
    /// `Label` renders separately below the container.
    private var jobsState: DataState {
        if model.isLoading && model.jobs.isEmpty { return .loading }
        if model.jobs.isEmpty { return .empty }
        return .content
    }

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
                    // 2026-05-21 add: manual refresh — useful right
                    // after the user deletes / launches a job and
                    // doesn't want to wait 45s for the next auto-
                    // poll. Spinner replaces the icon during the
                    // in-flight refresh so the user can't
                    // double-fire.
                    Button {
                        Task { await model.loadJobs() }
                    } label: {
                        if model.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isLoading)
                    .help("Refresh batch jobs now (or wait \(model.pollCountdown)s for the next auto-refresh)")
                    .accessibilityLabel("Refresh batch jobs")
                    // What opens the sheet, in sight: the summary opens it too,
                    // but nothing says so.
                    Button("Jobs & History…") { model.detailPresented = true }
                        .controlSize(.small)
                        .help("Show the batch jobs, and the history of those that ended")
                        .pointable("portal.batchJobs")
                }

                // Cross-fade only on the loading/empty/content BOUNDARY —
                // the 45 s auto-poll keeps the state at `.content` and
                // mutates the summary counts instantly underneath, no churn.
                DataStateContainer(state: jobsState) {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } empty: {
                    summaryButton {
                        Label("No batch jobs", systemImage: "tray")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } error: {
                    EmptyView()
                } content: {
                    summaryButton {
                        Text("\(model.jobs.count) total")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if model.hasError {
                    InlineErrorLabel(message: model.errorMessage)
                }
            }
        }
        .uiPresented("Batch Jobs", .sheet, isPresented: $model.detailPresented)
        .sheet(isPresented: $model.detailPresented) {
            HeadlessJobsDetailSheet(model: model)
        }
    }

    // MARK: - Summary

    /// The summary opens the Batch Jobs sheet too — with no jobs as well: its
    /// History keeps the jobs CANFAR no longer lists, and why they failed.
    private func summaryButton(@ViewBuilder footer: () -> some View) -> some View {
        Button { model.detailPresented = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                summaryRow
                footer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the batch jobs, and the history of those that ended")
    }

    /// Every count, zeros too (plan 17 U2): "0 running · 0 pending · 1 done · 1 failed".
    private var summaryRow: some View {
        HStack(spacing: 10) {
            ForEach(model.statusCounts, id: \.status) { count in
                statusPill(count, color: Self.color(count.status))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.statusSummary)
    }

    private static func color(_ status: HeadlessMonitorModel.StatusCount.Status) -> Color {
        switch status {
        case .running: return .green
        case .pending: return .orange
        case .done: return .blue
        case .failed: return .red
        }
    }

    private func statusPill(_ count: HeadlessMonitorModel.StatusCount, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(count.count == 0 ? 0.35 : 1)
            Text(verbatim: count.text)
                .font(.caption2)
                .foregroundStyle(count.count == 0 ? .tertiary : .secondary)
        }
    }
}
