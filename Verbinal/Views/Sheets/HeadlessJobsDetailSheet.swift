// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct HeadlessJobsDetailSheet: View {
    @Bindable var model: HeadlessMonitorModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = "running"
    @State private var eventsSheetJob: HeadlessJob?
    @State private var eventsText = ""
    @State private var logsText = ""

    private var tabs: [(id: String, label: String, count: Int, color: Color)] {
        [
            ("running", "Running", model.runningCount, .green),
            ("pending", "Pending", model.pendingCount, .orange),
            ("completed", "Completed", model.completedCount, .blue),
            ("failed", "Failed", model.failedCount, .red),
        ]
    }

    private var filteredJobs: [HeadlessJob] {
        model.jobs.filter { job in
            switch selectedTab {
            case "running": return job.isRunning
            case "pending": return job.isPending
            case "completed": return job.isCompleted
            case "failed": return job.isFailed
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Batch Jobs")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("(\(model.jobs.count) total)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            // Tab bar
            HStack(spacing: 4) {
                ForEach(tabs, id: \.id) { tab in
                    Button {
                        selectedTab = tab.id
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(tab.color)
                                .frame(width: 6, height: 6)
                            Text("\(tab.label) (\(tab.count))")
                                .font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selectedTab == tab.id ? tab.color.opacity(0.15) : Color.clear)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // Job list
            if filteredJobs.isEmpty {
                Spacer()
                Text("No \(selectedTab) jobs")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredJobs) { job in
                    jobRow(job)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(item: $eventsSheetJob) { job in
            SessionEventsSheet(
                title: job.name,
                events: eventsText,
                logs: logsText
            )
        }
    }

    // MARK: - Job Row

    private func jobRow(_ job: HeadlessJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .fontWeight(.medium)
                Text(job.imageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !job.cpuAllocated.isEmpty {
                Text("\(job.cpuAllocated)c")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !job.memoryAllocated.isEmpty {
                Text(job.memoryAllocated)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !job.startedTime.isEmpty {
                Text(formatTime(job.startedTime))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(job.status)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor(for: job).opacity(0.15))
                .foregroundStyle(statusColor(for: job))
                .clipShape(Capsule())
        }
        .contextMenu {
            Button("View Events & Logs") {
                Task { await showEvents(for: job) }
            }
            if job.isTerminal {
                Divider()
                Button("Delete", role: .destructive) {
                    Task { await model.deleteJob(id: job.id) }
                }
            }
        }
    }

    // MARK: - Helpers

    private func statusColor(for job: HeadlessJob) -> Color {
        switch job.status.lowercased() {
        case "running": return .green
        case "pending": return .orange
        case "completed", "succeeded": return .blue
        case "failed", "error": return .red
        default: return .gray
        }
    }

    private func formatTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateFormat = "MMM d, HH:mm"
            return display.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateFormat = "MMM d, HH:mm"
            return display.string(from: date)
        }
        return isoString
    }

    private func showEvents(for job: HeadlessJob) async {
        async let events = model.getEvents(id: job.id)
        async let logs = model.getLogs(id: job.id)
        eventsText = (await events) ?? "No events available"
        logsText = (await logs) ?? "No logs available"
        eventsSheetJob = job
    }
}
