// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

struct iOSSessionsTab: View {
    @Bindable var model: SessionListModel
    @Environment(\.openURL) private var openURL

    @State private var eventsSession: Session?
    @State private var eventsText: String?
    @State private var logsText: String?
    @State private var isLoadingEvents = false
    @State private var deletingSessionId: String?

    var body: some View {
        Group {
            if model.sessions.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No Active Sessions",
                    systemImage: "tray",
                    description: Text("Launch a session from the Launch tab")
                )
            } else {
                List {
                    ForEach(model.sessions) { session in
                        iOSSessionRow(session)
                            .opacity(deletingSessionId == session.id ? 0.4 : 1.0)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteSession(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if session.isRunning {
                                    Button {
                                        Task { await model.renewSession(id: session.id) }
                                    } label: {
                                        Label("Renew", systemImage: "clock.arrow.circlepath")
                                    }
                                    .tint(.blue)
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .refreshable { await model.loadSessions() }
        .navigationTitle("Sessions (\(model.sessions.count))")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.loadSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(item: $eventsSession) { session in
            iOSEventsSheet(
                session: session,
                events: eventsText,
                logs: logsText,
                isLoading: isLoadingEvents
            )
        }
        .overlay {
            if model.hasError {
                VStack {
                    Spacer()
                    Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            }
        }
    }

    // MARK: - Session Row

    @ViewBuilder
    private func iOSSessionRow(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: icon + name + status
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(typeColor(session).opacity(0.15))
                    if let asset = typeImageAsset(session) {
                        Image(asset)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: typeIcon(session))
                            .foregroundStyle(typeColor(session))
                    }
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.body)
                        .fontWeight(.semibold)
                    Text(shortImageLabel(session.containerImage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(session.status)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(session).opacity(0.15))
                    .foregroundStyle(statusColor(session))
                    .clipShape(Capsule())
            }

            // Times
            HStack(spacing: 12) {
                Label(formatTime(session.startedTime), systemImage: "clock")
                Spacer()
                Label(formatTime(session.expiresTime), systemImage: "timer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Resources
            HStack(spacing: 12) {
                if !session.cpuAllocated.isEmpty {
                    Label("CPU: \(session.cpuAllocated)", systemImage: "cpu")
                }
                if !session.memoryAllocated.isEmpty {
                    Label("RAM: \(session.memoryAllocated)", systemImage: "memorychip")
                }
                Spacer()
                if !session.isFixedResources {
                    Text("FLEX")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            // Action buttons — large, obvious, touch-friendly
            HStack(spacing: 10) {
                Button {
                    if let url = model.connectURL(for: session) { openURL(url) }
                } label: {
                    Label("Open", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(!session.isRunning)

                Button {
                    showEvents(for: session)
                } label: {
                    Label("Logs", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func deleteSession(_ session: Session) {
        deletingSessionId = session.id
        Task {
            await model.deleteSession(id: session.id)
            deletingSessionId = nil
        }
    }

    private func showEvents(for session: Session) {
        // Show sheet immediately with loading state
        eventsText = nil
        logsText = nil
        isLoadingEvents = true
        eventsSession = session

        Task {
            async let e = model.getSessionEvents(id: session.id)
            async let l = model.getSessionLogs(id: session.id)
            eventsText = await e
            logsText = await l
            isLoadingEvents = false
        }
    }

    // MARK: - Helpers

    private func shortImageLabel(_ image: String) -> String {
        String(image.split(separator: "/").last ?? Substring(image))
    }

    private func statusColor(_ session: Session) -> Color {
        switch session.status.lowercased() {
        case "running": return .green
        case "pending": return .orange
        case "failed", "error": return .red
        case "terminating": return .gray
        default: return .gray
        }
    }

    private func typeColor(_ session: Session) -> Color {
        switch session.sessionType.lowercased() {
        case "notebook": return .blue
        case "desktop": return .purple
        case "carta": return .teal
        case "contributed": return Color(.systemOrange)
        case "firefly": return .orange
        default: return .secondary
        }
    }

    private func typeImageAsset(_ session: Session) -> String? {
        switch session.sessionType.lowercased() {
        case "notebook": return "session-notebook"
        case "desktop": return "session-desktop"
        case "carta": return "session-carta"
        case "contributed": return "session-contributed"
        case "firefly": return "session-firefly"
        default: return nil
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

    private func typeIcon(_ session: Session) -> String {
        switch session.sessionType.lowercased() {
        case "notebook": return "book.pages"
        case "desktop": return "desktopcomputer"
        case "carta": return "map"
        case "contributed": return "shippingbox"
        case "firefly": return "flame"
        default: return "questionmark.square"
        }
    }
}

// MARK: - Events Sheet (immediate open, loading inside)

private struct iOSEventsSheet: View {
    let session: Session
    let events: String?
    let logs: String?
    let isLoading: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    private var currentContent: String {
        selectedTab == 0 ? (events ?? "") : (logs ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Events").tag(0)
                    Text("Logs").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if isLoading {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                } else {
                    ScrollView {
                        Text(currentContent.isEmpty ? "No data available" : currentContent)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .background(Color.textFieldBackground)
                }
            }
            .navigationTitle(session.sessionName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        PlatformClipboard.copy(currentContent)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(isLoading || currentContent.isEmpty)
                }
            }
        }
    }
}
#endif
