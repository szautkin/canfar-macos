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

    /// Job currently anchoring the info popover. Per-row `@State`
    /// bools would force a popover modifier on each row, which
    /// SwiftUI handles poorly inside a `List`. Single optional at
    /// the parent level + per-row identity check keeps the
    /// hierarchy clean.
    @State private var infoPopoverJobID: String?

    /// Job awaiting the running-only delete confirmation dialog.
    /// Terminated jobs bypass this — they delete on click since
    /// they're metadata-only removal (no live container to stop).
    @State private var deleteConfirmJob: HeadlessJob?

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
                Text("(\(String(model.jobs.count)) total)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                // 2026-05-21 add: manual refresh next to Close.
                // The polling cadence (45s) is slow when the user
                // just touched a job and wants to confirm Skaha's
                // state. Spinner replaces the icon during in-flight
                // refresh; ⌘R keyboard shortcut for power users.
                Button {
                    Task { await model.loadJobs() }
                } label: {
                    if model.isLoading {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isLoading)
                .help("Refresh batch jobs from Skaha now (auto-refresh fires every 45s)")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close this dialog (⎋)")
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
                            Text("\(tab.label) (\(String(tab.count)))")
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
        .sheetFrame(minWidth: 600, minHeight: 400)
        .sheet(item: $eventsSheetJob) { job in
            SessionEventsSheet(
                title: job.name,
                events: eventsText,
                logs: logsText
            )
        }
        // Single confirmation dialog at sheet level — only
        // running / pending jobs trip this (terminated ones
        // delete on click since they're metadata-only).
        // `confirmationDialog` is the macOS-native pattern for
        // destructive-with-explanation per the 2026-05-19 UX
        // consult; Alert would also work but
        // confirmationDialog reads as more action-focused.
        .confirmationDialog(
            "Stop and delete this running job?",
            isPresented: Binding(
                get: { deleteConfirmJob != nil },
                set: { if !$0 { deleteConfirmJob = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteConfirmJob
        ) { job in
            Button("Stop and Delete", role: .destructive) {
                let id = job.id
                deleteConfirmJob = nil
                Task { await model.deleteJob(id: id) }
            }
            Button("Cancel", role: .cancel) {
                deleteConfirmJob = nil
            }
        } message: { job in
            Text("The container for \"\(job.name)\" will be killed immediately and any unsaved work inside it will be lost.")
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
                // Route through the popover's formatter so the
                // row reads "1Gi" instead of Skaha's noisy
                // "1.07Gi" round-trip (1 GiB binary ≈ 1.073 GB
                // decimal). Single source of truth between the
                // row and the popover's Resources section.
                Text(HeadlessJobInfoPopover.formatMemory(job.memoryAllocated))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !job.startedTime.isEmpty {
                Text(formatTime(job.startedTime))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(verbatim: SessionDisplay.localizedStatus(job.status))
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor(for: job).opacity(0.15))
                .foregroundStyle(statusColor(for: job))
                .clipShape(Capsule())

            // Trailing icon strip: info + delete. Always visible
            // (not hover-revealed) per the 2026-05-19 UX consult —
            // hover-reveal is invisible to first-time users at
            // this row density (40pt) and has no keyboard path.
            // Mirrors Finder's Tags column / Notes' attachment-row
            // affordances.
            infoIconButton(for: job)
            deleteIconButton(for: job)
        }
        .contextMenu {
            // Keep the context menu too — power users who already
            // learned the right-click flow shouldn't lose it.
            // The icons just make the actions discoverable for
            // everyone else.
            Button("View Events & Logs") {
                Task { await showEvents(for: job) }
            }
            Divider()
            Button(job.isTerminal ? "Delete" : "Stop and Delete",
                   role: .destructive) {
                if job.isTerminal {
                    Task { await model.deleteJob(id: job.id) }
                } else {
                    deleteConfirmJob = job
                }
            }
        }
        // Single popover per parent View, anchored to the row
        // currently held in `infoPopoverJobID`. Per-row
        // `.popover(isPresented:)` modifiers inside a `List`
        // misbehave in SwiftUI (popover anchor shifts to the
        // first row on scroll). This pattern keeps the anchor
        // stable.
        .popover(
            isPresented: Binding(
                get: { infoPopoverJobID == job.id },
                set: { if !$0 { infoPopoverJobID = nil } }
            ),
            arrowEdge: .trailing
        ) {
            HeadlessJobInfoPopover(job: job)
        }
        // Group children for VoiceOver so a 15-row list is 15
        // focusable elements, not 45 (one row + 2 icons each).
        // Custom actions expose the icon behaviours to assistive
        // tech without bloating the focus chain — pattern from
        // Mail / Reminders per HIG's "Actions in Lists" guidance.
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            // Per the 2026-05-19 UX consult: keep the row a
            // single focusable element while still exposing
            // both icon behaviours to assistive tech via the
            // rotor. Mirrors Mail / Reminders.
            Button("Show details") { infoPopoverJobID = job.id }
            if !model.deletingJobIDs.contains(job.id) {
                Button(job.isTerminal ? "Delete job" : "Stop and delete job") {
                    if job.isTerminal {
                        Task { await model.deleteJob(id: job.id) }
                    } else {
                        deleteConfirmJob = job
                    }
                }
            }
        }
    }

    // MARK: - Icon buttons

    private func infoIconButton(for job: HeadlessJob) -> some View {
        Button {
            infoPopoverJobID = job.id
        } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Show job details")
        .accessibilityLabel("Job details")
        .accessibilityHint("Opens a popover with the job's id, image, resources, and timing.")
    }

    @ViewBuilder
    private func deleteIconButton(for job: HeadlessJob) -> some View {
        if model.deletingJobIDs.contains(job.id) {
            // In-flight: pulsing hourglass while the round-trip
            // completes. Replaces the trash entirely so the user
            // can't double-click during the in-flight window.
            Image(systemName: "hourglass")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityLabel("Delete in progress")
        } else {
            Button(role: .destructive) {
                if job.isTerminal {
                    // Metadata-only removal — single tap.
                    Task { await model.deleteJob(id: job.id) }
                } else {
                    // Live container — destructive confirm first.
                    deleteConfirmJob = job
                }
            } label: {
                Image(systemName: "trash")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help(job.isTerminal ? "Delete job" : "Stop and delete this running job")
            .accessibilityLabel(job.isTerminal ? "Delete job" : "Stop and delete job")
            .accessibilityHint(job.isTerminal
                               ? "Removes the job from the list. Cannot be undone."
                               : "Stops the running container immediately. Requires confirmation.")
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
