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
        ListSessionsTool(fetchAll: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let raw = try await self.sessionService.getSessions()
            return raw.map(Self.flatten)
        })
    }

    func makeGetSessionTool() -> GetSessionTool {
        GetSessionTool(fetchAll: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let raw = try await self.sessionService.getSessions()
            return raw.map(Self.flatten)
        })
    }

    func makeListSessionImagesTool() -> ListSessionImagesTool {
        // Capture the existing ImageService — it already targets the
        // user-scoped Skaha catalogue and reuses the auth-aware
        // NetworkClient. Returning the raw (id, types) tuples keeps
        // the tool's Output struct decoupled from the model layer.
        let service = self.imageService
        return ListSessionImagesTool(fetch: {
            let raw = try await service.getImages()
            return raw.map { (id: $0.id, types: $0.types) }
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
                    image: $0.image, project: $0.project,
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
            memoryAllocated: s.memoryAllocated, memoryUsage: s.memoryUsage,
            cpuAllocated: s.cpuAllocated, cpuUsage: s.cpuUsage,
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
}
