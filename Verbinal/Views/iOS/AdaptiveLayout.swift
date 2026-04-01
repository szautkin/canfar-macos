// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

/// iPhone: TabView. iPad: NavigationSplitView with sidebar.
struct AdaptiveLayout: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    var body: some View {
        if sizeClass == .regular {
            iPadSplitView(
                sessionListModel: sessionListModel,
                sessionLaunchModel: sessionLaunchModel,
                platformLoadModel: platformLoadModel,
                storageModel: storageModel
            )
        } else {
            iOSTabView(
                sessionListModel: sessionListModel,
                sessionLaunchModel: sessionLaunchModel,
                platformLoadModel: platformLoadModel,
                storageModel: storageModel
            )
        }
    }
}

// MARK: - iPad Section Enum

private enum iPadSection: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case launch = "Launch Session"
    case monitor = "Monitor"
    case account = "Account"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sessions: return "rectangle.stack"
        case .launch: return "play.circle"
        case .monitor: return "gauge.with.dots.needle.33percent"
        case .account: return "person.circle"
        }
    }
}

// MARK: - iPad Split View

private struct iPadSplitView: View {
    @Environment(AppState.self) private var appState

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    @State private var selectedSection: iPadSection? = .sessions

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section {
                ForEach(iPadSection.allCases) { section in
                    NavigationLink(value: section) {
                        sidebarRow(section)
                    }
                }
            }

            // User info at bottom of sidebar
            if let info = appState.userInfo {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if let first = info.firstName {
                            let name = [first, info.lastName].compactMap { $0 }.joined(separator: " ")
                            Text(name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        if let email = info.email {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 6) {
                    Image("VerbinalIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                    Text("Verbinal")
                        .font(.headline)
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(_ section: iPadSection) -> some View {
        HStack {
            Label(section.rawValue, systemImage: section.icon)
            Spacer()
            switch section {
            case .sessions:
                if sessionListModel.sessions.count > 0 {
                    Text("\(sessionListModel.sessions.count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            case .monitor:
                if let hm = appState.headlessMonitor, hm.totalActive > 0 {
                    Text("\(hm.totalActive) active")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .sessions:
            NavigationStack {
                iPadSessionsDetail(model: sessionListModel)
            }
        case .launch:
            NavigationStack {
                iOSLaunchTab(
                    launchModel: sessionLaunchModel,
                    recentLaunchStore: appState.recentLaunchStore,
                    onLaunched: {
                        Task { await sessionListModel.loadSessions() }
                    }
                )
            }
        case .monitor:
            NavigationStack {
                iPadMonitorDetail(
                    storageModel: storageModel,
                    platformLoadModel: platformLoadModel
                )
            }
        case .account:
            NavigationStack {
                iOSAccountTab()
            }
        case .none:
            Text("Select a section")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - iPad Sessions (2-column grid)

private struct iPadSessionsDetail: View {
    @Bindable var model: SessionListModel
    @Environment(\.openURL) private var openURL

    @State private var eventsSession: Session?
    @State private var eventsText: String?
    @State private var logsText: String?
    @State private var isLoadingEvents = false
    @State private var deletingSessionId: String?

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            if model.sessions.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No Active Sessions",
                    systemImage: "tray",
                    description: Text("Launch a session from the sidebar")
                )
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.sessions) { session in
                        iPadSessionCard(session)
                    }
                }
                .padding()
            }

            if model.hasError {
                Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
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
            iOSEventsSheetWrapper(
                session: session,
                events: eventsText,
                logs: logsText,
                isLoading: isLoadingEvents
            )
        }
    }

    @ViewBuilder
    private func iPadSessionCard(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(SessionDisplay.typeColor(session.sessionType).opacity(0.15))
                    if let asset = SessionDisplay.typeImageAsset(session.sessionType) {
                        Image(asset)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: SessionDisplay.typeIcon(session.sessionType))
                            .foregroundStyle(SessionDisplay.typeColor(session.sessionType))
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.body)
                        .fontWeight(.semibold)
                    Text(SessionDisplay.shortImageLabel(session.containerImage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(session.status)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SessionDisplay.statusColor(session.status).opacity(0.15))
                    .foregroundStyle(SessionDisplay.statusColor(session.status))
                    .clipShape(Capsule())
            }

            Divider()

            // Times + Resources
            HStack {
                Label(SessionDisplay.formatTime(session.startedTime), systemImage: "clock")
                Spacer()
                Label(SessionDisplay.formatTime(session.expiresTime), systemImage: "timer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

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

            Divider()

            // Actions
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
                    Task { await model.renewSession(id: session.id) }
                } label: {
                    Label("Renew", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!session.isRunning)

                Button {
                    showEvents(for: session)
                } label: {
                    Label("Logs", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    deletingSessionId = session.id
                    Task {
                        await model.deleteSession(id: session.id)
                        deletingSessionId = nil
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator, lineWidth: 1)
        )
        .opacity(deletingSessionId == session.id ? 0.4 : 1.0)
    }

    private func showEvents(for session: Session) {
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
}

// MARK: - iPad Monitor (side-by-side widgets)

private struct iPadMonitorDetail: View {
    @Environment(AppState.self) private var appState

    var storageModel: StorageModel
    var platformLoadModel: PlatformLoadModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Top row: Storage + Batch Jobs side by side
                HStack(alignment: .top, spacing: 16) {
                    StorageQuotaView(model: storageModel)
                        .frame(maxWidth: .infinity)

                    if let hm = appState.headlessMonitor {
                        HeadlessJobsView(model: hm)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Platform Load full width
                PlatformLoadView(model: platformLoadModel)
            }
            .padding()
        }
        .navigationTitle("Monitor")
    }
}

// MARK: - Shared Events Sheet Wrapper

private struct iOSEventsSheetWrapper: View {
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
