// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct HeadlessJobsView: View {
    @Bindable var model: HeadlessMonitorModel


    var body: some View {
        PortalCardShell(title: "Batch Jobs", systemImage: "gearshape.2", phase: model.load,
                        reload: PortalReload(id: "portal.batchJobs.refresh", name: "Refresh batch jobs",
                                             help: "Refresh batch jobs now (or wait \(model.pollCountdown)s for the next auto-refresh)",
                                             action: { await model.loadJobs() }),
                        next: model.isPolling ? String(localized: "next in \(model.pollCountdown) s") : nil) {
            // What opens the sheet, in sight: the summary opens it too,
            // but nothing says so.
            Button("Jobs & History…") { model.detailPresented = true }
                .controlSize(.small)
                .help("Show the batch jobs, and the history of those that ended")
                .pointable("portal.batchJobs", opens: "Batch Jobs")
        } content: {
            // The 45 s poll keeps the summary and changes its counts
            // underneath; before the first load, the same summary, its line
            // a dash (plan 42).
            summaryButton {
                if model.load.value == nil {
                    Text(verbatim: "—")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if model.jobs.isEmpty {
                    Label("No batch jobs", systemImage: "tray")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(model.jobs.count) total")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
