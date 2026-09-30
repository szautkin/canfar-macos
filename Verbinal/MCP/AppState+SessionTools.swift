// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Sessions, headless jobs, recent launches, and platform load / quota.
extension AppState {
    // MARK: - Sessions

    func makeListSessionsTool() -> ListSessionsTool {
        let service = sessionService
        return ListSessionsTool(fetchAll: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let raw = try await self.sessionService.getSessions()
            return raw.map(Self.flatten)
        }, fetchApps: { try await service.desktopApps() })
    }

    func makeGetSessionTool() -> GetSessionTool {
        let service = sessionService
        return GetSessionTool(fetchAll: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let raw = try await self.sessionService.getSessions()
            return raw.map(Self.flatten)
        }, events: { id in try await service.getSessionEvents(id: id) })
    }

    func makeListSessionImagesTool() -> ListSessionImagesTool {
        // The user-scoped Skaha catalogue with the images the person
        // added from the registry. Returning the raw (id, types) tuples
        // keeps the tool's Output struct decoupled from the model layer.
        ListSessionImagesTool(fetch: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            return try await self.catalogueImages().map { (id: $0.id, types: $0.types) }
        })
    }

    // MARK: - Sessions parity (events, logs, connect)

    func makeGetSessionEventsTool() -> GetSessionEventsTool {
        let service = self.sessionService
        return GetSessionEventsTool(fetch: { id in
            try await service.getSessionEvents(id: id)
        })
    }

    func makeGetSessionLogsTool() -> GetSessionLogsTool {
        let service = self.sessionService
        return GetSessionLogsTool(fetch: { id in
            try await service.getSessionLogs(id: id)
        })
    }

    func makeOpenSessionTool() -> OpenSessionTool {
        let service = self.sessionService
        let activity = agentsService.activityStore
        return OpenSessionTool(open: { id in
            let sessions: [Session]
            do {
                sessions = try await service.getSessions()
            } catch {
                return .rejected("Could not list sessions: \(error.localizedDescription)")
            }
            guard let session = sessions.first(where: { $0.id == id }) else {
                return .rejected("No session with id '\(id)'")
            }
            guard session.isRunning else {
                return .rejected("Session '\(id)' is \(session.status), not Running")
            }
            guard let url = URL(string: session.connectUrl) else {
                return .rejected("Session '\(id)' has no valid connect URL")
            }
            return await MainActor.run {
                NSWorkspace.shared.open(url)
                activity.append(.live(
                    kind: "open_session",
                    summary: "Opened session '\(session.sessionName)' in the browser",
                    origin: .external(clientID: "open_session")))
                return .opened(url.absoluteString)
            }
        })
    }

    // MARK: - Headless / batch

    func makeListHeadlessJobsTool() -> ListHeadlessJobsTool {
        let service = self.headlessService
        return ListHeadlessJobsTool(fetch: {
            try await service.getHeadlessJobs()
        })
    }

    func makeGetHeadlessJobTool() -> GetHeadlessJobTool {
        let service = self.headlessService
        return GetHeadlessJobTool(fetch: {
            try await service.getHeadlessJobs()
        })
    }

    func makeGetHeadlessJobLogsTool() -> GetHeadlessJobLogsTool {
        let service = self.headlessService
        return GetHeadlessJobLogsTool(fetch: { id in
            try await service.getLogs(id: id)
        })
    }

    func makeGetHeadlessJobEventsTool() -> GetHeadlessJobEventsTool {
        let service = self.headlessService
        return GetHeadlessJobEventsTool(fetch: { id in
            try await service.getEvents(id: id)
        })
    }

    // MARK: - Recent launches

    func makeListRecentLaunchesTool(store: RecentLaunchStore) -> ListRecentLaunchesTool {
        ListRecentLaunchesTool(snapshot: { @MainActor in
            store.launches.map {
                RecentLaunchOut(
                    id: $0.id.uuidString, name: $0.name, type: $0.type,
                    image: $0.image, project: $0.imageProject,
                    resourceType: $0.resourceType,
                    cores: $0.cores, ram: $0.ram, gpus: $0.gpus,
                    launchedAt: $0.launchedAt
                )
            }
        })
    }

    // Pure data-shape transform — no actor state. `nonisolated`
    // lets it be passed to `map` from any context, closing the
    // "@MainActor function value losing global actor" warnings
    // at every map call site that used to require a MainActor hop.
    private nonisolated static func flatten(_ s: Session) -> SessionOut {
        SessionOut(
            id: s.id, name: s.sessionName, type: s.sessionType,
            status: s.status, image: s.containerImage,
            connectURL: s.connectUrl,
            startedTime: s.startedTime, expiresTime: s.expiresTime,
            memoryAllocated: s.ramGiven, memoryUsage: s.memoryUsage,
            cpuAllocated: s.coresGiven, cpuUsage: s.cpuUsage,
            gpuAllocated: s.gpuAllocated
        )
    }

    // MARK: - Platform & quota reads

    func makeGetPlatformLoadTool() -> GetPlatformLoadTool {
        let service = platformService
        return GetPlatformLoadTool(fetch: {
            let stats = try await service.getStats()
            return GetPlatformLoadTool.Output(
                instances: stats.instances.map {
                    .init(session: $0.session, desktopApp: $0.desktopApp,
                          headless: $0.headless, total: $0.total)
                },
                cores: stats.cores.map {
                    .init(requested: $0.requestedCPUCores, available: $0.cpuCoresAvailable)
                },
                ram: stats.ram.map {
                    .init(requestedGB: $0.requestedRAM.map { PlatformLoadModel.parseRamGB($0) },
                          availableGB: $0.ramAvailable.map { PlatformLoadModel.parseRamGB($0) })
                }
            )
        })
    }

    func makeGetStorageQuotaTool() -> GetStorageQuotaTool {
        let service = storageService
        return GetStorageQuotaTool(fetch: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let user = await self.username
            guard !user.isEmpty else { throw ToolFailureReason.authRequired }
            let quota = try await service.getQuota(username: user)
            return GetStorageQuotaTool.Output(
                usedBytes: quota.usedBytes, quotaBytes: quota.quotaBytes,
                usedGB: quota.usedGB, quotaGB: quota.quotaGB,
                usagePercent: quota.usagePercent
            )
        })
    }

    // MARK: - The launch form

    func makeShowLaunchFormTool() -> ShowLaunchFormTool {
        ShowLaunchFormTool(show: { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("App state unavailable") }
            return try await MainActor.run {
                if args.close == true {
                    self.launchFormPresented = false
                    return LaunchFormShown(shown: false, tab: nil, image: nil, imageSource: nil)
                }
                guard self.isAuthenticated else {
                    throw ToolFailureReason.targetNotResolved("the Portal needs the person signed in to CANFAR")
                }
                let trimmed = args.image?.trimmingCharacters(in: .whitespacesAndNewlines)
                let image = trimmed?.isEmpty == false ? trimmed : nil
                let tab = args.tab.flatMap { ShowLaunchFormTool.tabs[$0.lowercased()] }
                let inCatalogue = image.map { id in self.canfarImagesModel?.allImages.contains { $0.id == id } ?? false }
                self.navigateTo(.portal)
                self.launchFormRequest = LaunchFormRequest(tab: tab, image: image)
                self.agentsService.activityStore.append(.live(
                    kind: "show_launch_form", summary: "Opened the launch form", origin: .external(clientID: "show_launch_form")))
                let shownTab = tab ?? (inCatalogue == false ? .advanced : self.launchFormTab)
                return LaunchFormShown(shown: true, tab: ShowLaunchFormTool.tabs.first { $0.value == shownTab }?.key, image: image,
                                       imageSource: inCatalogue.map { $0 ? "catalogue" : "custom" })
            }
        })
    }
}
