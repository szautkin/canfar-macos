// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The Portal on iPhone and iPad (plan 47 1.2): status first. What needs the
/// person comes first, and only when there is something; then sessions,
/// batch jobs, Remote Compute, the platform and storage. A few actions, each
/// one saying what came of it; Delete asks first.
struct iOSPortalView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var sessions: SessionListModel
    var launchModel: SessionLaunchModel
    var platformLoad: PlatformLoadModel
    var storage: StorageModel
    var seen: PortalSeenStore
    var onRescheduleReminders: () -> Void
    var onOpenCompute: () -> Void

    @State private var logsFor: Session?
    @State private var deleting: Session?
    @State private var busyID: String?
    @State private var notice: String?
    @State private var showLaunch = false
    /// Moves on every minute, so "expires in" stays true while the person looks.
    @State private var now = Date()
    /// The rings at the top of the list are in sight.
    @State private var ringsInSight = true
    /// The pinned rings, shown while scrolled down: half size until tapped.
    @State private var pinnedLarge = false
    /// Where the list stood when the pinned rings were opened: a scroll from
    /// there makes them half size again.
    @State private var openedAt: CGFloat?
    /// The last scroll position seen (iOS 18 and later).
    @State private var lastOffset: CGFloat = 0

    var body: some View {
        List {
            ringsSection
            attentionSection
            sessionsSection
            jobsSection
            computeSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshAll() }
        .overlay(alignment: .top) { pinnedRings }
        .modifier(ScrollOffsetObserver { offset in scrolled(to: offset) })
        .navigationTitle("Portal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showLaunch = true
                } label: {
                    Label("Launch Session", systemImage: "plus")
                }
            }
        }
        .sheet(item: $logsFor) { session in
            iOSSessionLogsSheet(session: session, model: sessions)
        }
        .sheet(isPresented: $showLaunch) {
            iOSLaunchSheet(launchModel: launchModel, recentLaunchStore: appState.recentLaunchStore) {
                Task { await sessions.loadSessions() }
            }
        }
        .sheet(isPresented: jobsPresented) {
            if let monitor = appState.headlessMonitor {
                HeadlessJobsDetailSheet(model: monitor)
                    .iosSheetChrome()
            }
        }
        .confirmationDialog("Delete Session", isPresented: deletingPresented, presenting: deleting) { session in
            Button("Delete", role: .destructive) { delete(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Are you sure you want to delete '\(session.sessionName)'? This action cannot be undone.")
        }
        .overlay(alignment: .bottom) { noticeView }
        .task { await appState.remoteComputeModel.refresh(quiet: true) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }

    // MARK: - Needs attention

    private var attention: [PortalAttention.Item] {
        let jobs = appState.headlessMonitor?.jobs ?? []
        let compute = appState.remoteComputeModel
        let computeProblem = compute.snapshot?.problem ?? (compute.state == .failed ? compute.state.title : nil)
        return PortalAttention.items(
            signedIn: appState.isAuthenticated,
            sessions: sessions.sessions.map(\.attentionFacts),
            jobs: jobs.map { PortalAttention.JobFacts(id: $0.id, name: $0.name, status: $0.status) },
            seenFailedJobs: seen.seenFailedJobs,
            computeProblem: computeProblem,
            storagePercent: storage.hasData ? storage.usagePercent : nil,
            now: now)
    }

    @ViewBuilder
    private var attentionSection: some View {
        let items = attention
        if let problem = sessions.load.problem {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Try Again") { Task { await sessions.loadSessions() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        if !items.isEmpty {
            Section("Needs attention") {
                ForEach(items) { item in
                    attentionRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: PortalAttention.Item) -> some View {
        let session = item.subjectID.flatMap { id in sessions.sessions.first { $0.id == id } }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: item.kind))
                .foregroundStyle(color(for: item.kind))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold))
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // Icons, large, as on the session rows; each says its name to VoiceOver.
            switch item.kind {
            case .sessionExpiring:
                if let session {
                    Button { renew(session) } label: { attentionLabel("Renew", "clock.arrow.circlepath") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busyID != nil)
                }
            case .sessionFailed, .sessionStuck:
                if let session {
                    Button { logsFor = session } label: { attentionLabel("Events", "doc.text") }
                        .buttonStyle(.bordered)
                }
            case .jobFailed:
                Button { openJobs() } label: { attentionLabel("Logs", "doc.text") }
                    .buttonStyle(.bordered)
            case .compute:
                Button { onOpenCompute() } label: { attentionLabel("Open", "terminal") }
                    .buttonStyle(.bordered)
            case .signIn:
                Button { appState.showLoginSheet = true } label: { attentionLabel("Login", "person.crop.circle") }
                    .buttonStyle(.borderedProminent)
            case .storageFull:
                EmptyView()
            }
        }
        .swipeActions(edge: .trailing) {
            if item.kind == .jobFailed, let id = item.subjectID {
                Button("Seen") { markJobsSeen([id]) }
                    .tint(.gray)
            }
        }
    }

    private func attentionLabel(_ title: LocalizedStringKey, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 36)
    }

    private func icon(for kind: PortalAttention.Item.Kind) -> String {
        switch kind {
        case .signIn: return "person.crop.circle.badge.exclamationmark"
        case .sessionFailed, .jobFailed: return "xmark.octagon.fill"
        case .sessionExpiring: return "timer"
        case .sessionStuck: return "hourglass"
        case .compute: return "terminal"
        case .storageFull: return "externaldrive.fill.badge.exclamationmark"
        }
    }

    private func color(for kind: PortalAttention.Item.Kind) -> Color {
        switch kind {
        case .sessionFailed, .jobFailed: return .red
        case .sessionExpiring, .sessionStuck, .storageFull, .compute: return .orange
        case .signIn: return .accentColor
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        Section {
            if sessions.sessions.isEmpty {
                if sessions.load.isWorking {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Button {
                        showLaunch = true
                    } label: {
                        Label("No active sessions. Launch one", systemImage: "play.circle")
                    }
                }
            } else {
                ForEach(sessions.sessions) { session in
                    iOSSessionRow(
                        session: session,
                        isBusy: busyID == session.id,
                        onOpen: { open(session) },
                        onRenew: { renew(session) },
                        onLogs: { logsFor = session },
                        onDelete: { deleting = session })
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if session.isRunning {
                            Button {
                                renew(session)
                            } label: {
                                Label("Renew", systemImage: "clock.arrow.circlepath")
                            }
                            .tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            deleting = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        } header: {
            Text("Sessions (\(sessions.sessions.count))")
        }
    }

    // MARK: - Batch jobs

    @ViewBuilder
    private var jobsSection: some View {
        if let monitor = appState.headlessMonitor {
            Section("Batch Jobs") {
                Button {
                    openJobs()
                } label: {
                    HStack {
                        if monitor.load.value == nil {
                            ProgressView()
                        } else if monitor.jobs.isEmpty {
                            Text("No batch jobs").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 10) {
                                ForEach(monitor.statusCounts, id: \.status) { count in
                                    jobCount(count)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(monitor.statusSummary))
            }
        }
    }

    private func jobCount(_ count: HeadlessMonitorModel.StatusCount) -> some View {
        let color: Color = switch count.status {
        case .running: .green
        case .pending: .orange
        case .done: .blue
        case .failed: .red
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7).opacity(count.count == 0 ? 0.35 : 1)
            Text(verbatim: count.text)
                .font(.caption)
                .foregroundStyle(count.count == 0 ? .tertiary : .primary)
        }
    }

    // MARK: - Remote Compute

    private var computeSection: some View {
        let compute = appState.remoteComputeModel
        return Section("Remote Compute") {
            Button(action: onOpenCompute) {
                HStack {
                    Label(compute.state.title, systemImage: "terminal")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - The platform and storage

    /// First in the list: the rings, large, with their numbers.
    private var ringsSection: some View {
        Section {
            iOSPlatformDonuts(platformLoad: platformLoad, storage: storage, compact: false)
                .padding(.vertical, 4)
                .onAppear { ringsInSight = true }
                .onDisappear {
                    ringsInSight = false
                    pinnedLarge = false
                }
        }
    }

    /// Scrolled down, the rings stay at the top at half size; a tap shows
    /// them large, with their numbers, and a scroll makes them half size again.
    @ViewBuilder
    private var pinnedRings: some View {
        if !ringsInSight {
            iOSPlatformDonuts(platformLoad: platformLoad, storage: storage, compact: !pinnedLarge)
                .padding(.horizontal, 16)
                .padding(.vertical, pinnedLarge ? 12 : 6)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAppAnimation(AppMotion.quick, reduceMotion: reduceMotion) { pinnedLarge.toggle() }
                    openedAt = pinnedLarge ? lastOffset : nil
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(pinnedLarge ? Text("Shows them smaller") : Text("Shows the numbers"))
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func scrolled(to offset: CGFloat) {
        lastOffset = offset
        guard pinnedLarge, let openedAt, abs(offset - openedAt) > 24 else { return }
        withAppAnimation(AppMotion.quick, reduceMotion: reduceMotion) { pinnedLarge = false }
        self.openedAt = nil
    }

    // MARK: - Actions

    private var deletingPresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var jobsPresented: Binding<Bool> {
        Binding(get: { appState.headlessMonitor?.detailPresented ?? false },
                set: { appState.headlessMonitor?.detailPresented = $0 })
    }

    private func open(_ session: Session) {
        guard let url = sessions.connectURL(for: session) else { return }
        openURL(url)
    }

    private func renew(_ session: Session) {
        busyID = session.id
        Task {
            await sessions.renewSession(id: session.id)
            busyID = nil
            if sessions.load.problem == nil {
                show(String(localized: "Renewed '\(session.sessionName)'"))
            }
            onRescheduleReminders()
        }
    }

    private func delete(_ session: Session) {
        busyID = session.id
        Task {
            await sessions.deleteSession(id: session.id)
            busyID = nil
            if sessions.load.problem == nil {
                show(String(localized: "Session '\(session.sessionName)' deleted."))
            }
            onRescheduleReminders()
        }
    }

    /// The jobs sheet; the failed jobs in it are seen from now on.
    private func openJobs() {
        guard let monitor = appState.headlessMonitor else { return }
        markJobsSeen(monitor.jobs.filter(\.isFailed).map(\.id))
        monitor.detailPresented = true
    }

    private func markJobsSeen(_ ids: [String]) {
        let failed = Set((appState.headlessMonitor?.jobs ?? []).filter(\.isFailed).map(\.id))
        seen.markSeen(ids, stillFailed: failed)
    }

    private func refreshAll() async {
        let monitor = appState.headlessMonitor
        let compute = appState.remoteComputeModel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sessions.loadSessions() }
            group.addTask { await monitor?.loadJobs() }
            group.addTask { await platformLoad.loadStats() }
            group.addTask { await storage.reload() }
            group.addTask { await compute.refresh(quiet: true) }
        }
    }

    // MARK: - Notice

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if notice == text { notice = nil } }
        }
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .sensoryFeedback(.success, trigger: notice)
        }
    }
}

extension Session {
    /// This session as the Portal's rules read it.
    var attentionFacts: PortalAttention.SessionFacts {
        PortalAttention.SessionFacts(id: id, name: sessionName, status: status,
                                     started: SessionTimes.date(startedTime), expires: SessionTimes.date(expiresTime))
    }
}

/// Hands on where the list stands as it scrolls (iOS 18 and later; earlier,
/// nothing: the pinned rings then change size only when tapped).
private struct ScrollOffsetObserver: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                onChange(offset)
            }
        } else {
            content
        }
    }
}
