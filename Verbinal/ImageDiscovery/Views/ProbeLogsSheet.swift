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
    /// Each tab's text: loading, loaded, or why not (plan 38) — its own,
    /// so one tab's failure is not the other's.
    @State private var logs: Phase<String> = .idle
    @State private var events: Phase<String> = .idle

    private var current: Phase<String> { tab == .logs ? logs : events }

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
            .background(Color.textFieldBackground)

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
            if current.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        PhaseView(phase: current, isEmpty: \.isEmpty, retry: { Task { await load(tab) } }) {
            monospaced(tab == .logs ? "(no log output)" : "(no events)")
        } content: { text in
            monospaced(text)
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
            Button("Refresh") { Task { await load(tab) } }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(current.isWorking)
            .help("Re-fetch the current tab from Skaha (⌘R)")

            Spacer()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .help("Close this dialog (⎋)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Loading

    private func loadCurrentTabIfNeeded() async {
        if current == .idle { await load(tab) }
    }

    /// Fetches `which` tab's text, keeping what it showed until it lands.
    private func load(_ which: Tab) async {
        switch which {
        case .logs:
            let attempt = logs.begin()
            do {
                logs.finish(attempt, with: .success(try await model.fetchLogs(jobID: jobID)))
            } catch {
                logs.finish(attempt, with: .failure(Problem(.other, String(localized: "Couldn't fetch logs: \(error.localizedDescription)"))))
            }
        case .events:
            let attempt = events.begin()
            do {
                events.finish(attempt, with: .success(try await model.fetchEvents(jobID: jobID)))
            } catch {
                events.finish(attempt, with: .failure(Problem(.other, String(localized: "Couldn't fetch events: \(error.localizedDescription)"))))
            }
        }
    }
}
