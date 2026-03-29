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

// MARK: - iPad Split View

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

private struct iPadSplitView: View {
    @Environment(AppState.self) private var appState

    var sessionListModel: SessionListModel
    var sessionLaunchModel: SessionLaunchModel
    var platformLoadModel: PlatformLoadModel
    var storageModel: StorageModel

    @State private var selectedSection: iPadSection? = .sessions

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(iPadSection.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.rawValue, systemImage: section.icon)
                    }
                }
            }
            .navigationTitle("Verbinal")
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .sessions:
            NavigationStack {
                iOSSessionsTab(model: sessionListModel)
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
                iOSMonitorTab(
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
#endif
