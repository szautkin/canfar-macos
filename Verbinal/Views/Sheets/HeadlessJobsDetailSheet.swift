// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct HeadlessJobsDetailSheet: View {
    @Bindable var model: HeadlessMonitorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    // Labels routed through the catalog — tuple Strings interpolated
    // into Text are NOT auto-localized like Text literals are.
    private var tabs: [(id: String, label: String, count: Int, color: Color)] {
        [
            ("running", String(localized: "Running"), model.runningCount, .green),
            ("pending", String(localized: "Pending"), model.pendingCount, .orange),
            ("completed", String(localized: "Completed"), model.completedCount, .blue),
            ("failed", String(localized: "Failed"), model.failedCount, .red),
        ] + (model.history.map { [("history", String(localized: "History"), $0.jobs.count, .gray)] } ?? [])
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
                    .font(.headline)
                Text("(\(String(model.jobs.count)) total)")
                    .font(.subheadline)
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
                .help("Refresh batch jobs from Skaha now")
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
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

            // Job list — filtered once a pass, not once to ask and again to show.
            let jobs = filteredJobs
            if selectedTab == "history", let history = model.history {
                JobHistoryList(history: history)
            } else if jobs.isEmpty {
                Spacer()
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(jobs) { job in
                    jobRow(job)
                }
                .listStyle(.inset)
            }
        }
        .sheetFrame(minWidth: 600, minHeight: 400)
        .onAppear { selectedTab = Self.firstTab(tabs.map { ($0.id, $0.count) }) }
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
        .accessibilityLabel(Text("Job details"))
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
            // can't double-click during the in-flight window. The
            // repeating pulse is suppressed entirely under Reduce
            // Motion — a static glyph still conveys the in-flight
            // state without an endless animation.
            Image(systemName: "hourglass")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
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
            .accessibilityLabel(Text("Delete job"))
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

    /// The tab it opens on: the first with anything in it — History when
    /// nothing is listed now — else Running.
    static func firstTab(_ counts: [(id: String, count: Int)]) -> String {
        counts.first { $0.count > 0 }?.id ?? "running"
    }

    /// Whole sentences per tab (not "No \(tab) jobs") so French gets
    /// correct grammar: « Aucune tâche en cours », not a raw English
    /// tab id interpolated into a template.
    private var emptyStateText: String {
        switch selectedTab {
        case "running":   return String(localized: "No running jobs")
        case "pending":   return String(localized: "No pending jobs")
        case "completed": return String(localized: "No completed jobs")
        default:          return String(localized: "No failed jobs")
        }
    }

    private func statusColor(for job: HeadlessJob) -> Color {
        switch job.status.lowercased() {
        case "running": return .green
        case "pending": return .orange
        case "completed", "succeeded": return .blue
        case "failed", "error": return .red
        default: return .gray
        }
    }

    /// Parsed by the shared formatters: a list of ten thousand scrolls
    /// without making two formatters for every row it shows.
    private func formatTime(_ isoString: String) -> String {
        SharedFormatters.isoDate(isoString)?.formatted(date: .abbreviated, time: .shortened) ?? isoString
    }

    private func showEvents(for job: HeadlessJob) async {
        async let events = model.getEvents(id: job.id)
        async let logs = model.getLogs(id: job.id)
        eventsText = SessionDisplay.logResultText(await events, emptyFallback: String(localized: "No events available"))
        logsText = SessionDisplay.logResultText(await logs, emptyFallback: String(localized: "No logs available"))
        eventsSheetJob = job
    }
}

/// The jobs CANFAR no longer lists — the only place a failure from an hour
/// ago still has its reason.
private struct JobHistoryList: View {
    var history: JobHistoryStore

    var body: some View {
        if history.jobs.isEmpty {
            Spacer()
            Text("Nothing has finished yet. Jobs appear here as they end, and stay after CANFAR removes them.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        } else {
            HStack {
                Text("Kept on this Mac after CANFAR removes the job.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History") { history.clear() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            List(history.jobs) { job in
                let failed = job.outcome == .failed
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? .red : .green)
                        .accessibilityLabel(Text(failed ? "Failed" : "Succeeded"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name).fontWeight(.medium)
                        // The reason when there is one; otherwise what it was.
                        Text(failed && job.failureReason?.isEmpty == false ? "\(job.summary) — \(job.failureReason ?? "")" : job.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(SharedFormatters.userMediumDateShortTime.string(from: job.finishedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
        }
    }
}
