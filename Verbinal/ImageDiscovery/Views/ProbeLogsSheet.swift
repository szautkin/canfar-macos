// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Modal sheet presented from the Image Discovery sheet when the
/// user clicks "View logs" on a failed row. Shows container
/// stdout/stderr and Kubernetes-level events for the probe's
/// Skaha session id, side-by-side via a segmented picker so the
/// user can flip between them without re-fetching.
///
/// Lazy-loads each pane the first time the user selects its tab.
/// "Refresh" re-fetches the current tab. Both fetches go through
/// the model → coordinator → HeadlessProbeLauncher facade, so
/// tests can mock the responses end-to-end.
struct ProbeLogsSheet: View {
    @Bindable var model: ImageDiscoveryModel
    var jobID: String

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .logs
    @State private var logs: String?
    @State private var events: String?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    enum Tab: String, CaseIterable, Identifiable {
        case logs = "Logs"
        case events = "Events"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onChange(of: tab) { _, _ in
                Task { await loadCurrentTabIfNeeded() }
            }

            Divider()

            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(NSColor.textBackgroundColor))

            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 420, idealHeight: 540)
        .task { await loadCurrentTabIfNeeded() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Probe Job Diagnostics")
                    .font(.headline)
                Text(jobID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            switch tab {
            case .logs:
                if let logs {
                    monospaced(logs.isEmpty ? "(no log output)" : logs)
                } else {
                    ProgressView("Loading logs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .events:
                if let events {
                    monospaced(events.isEmpty ? "(no events)" : events)
                } else {
                    ProgressView("Loading events…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            Button("Refresh") {
                switch tab {
                case .logs:   logs = nil
                case .events: events = nil
                }
                Task { await loadCurrentTabIfNeeded() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isLoading)

            Spacer()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Loading

    private func loadCurrentTabIfNeeded() async {
        switch tab {
        case .logs where logs == nil:    await loadLogs()
        case .events where events == nil: await loadEvents()
        default: break
        }
    }

    private func loadLogs() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            logs = try await model.fetchLogs(jobID: jobID)
        } catch {
            errorMessage = "Couldn't fetch logs: \(error.localizedDescription)"
        }
    }

    private func loadEvents() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            events = try await model.fetchEvents(jobID: jobID)
        } catch {
            errorMessage = "Couldn't fetch events: \(error.localizedDescription)"
        }
    }
}
