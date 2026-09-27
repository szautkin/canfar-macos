// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Image discovery: package search over cached manifests and the
/// discovery sheet's diagnostics.
extension AppState {
    func makeFindImagesWithPackagesTool() -> FindImagesWithPackagesTool {
        // Three closures because the tool needs three orthogonal
        // signals from app state: query the cache, snapshot the
        // live catalogue (id + types for filtering), enumerate
        // what's been probed. All auth-scoped; pre-auth returns
        // empty for everything, which keeps the response shape
        // stable for the agent.
        return FindImagesWithPackagesTool(
            search: { [weak self] query in
                guard let coord = await self?.imageDiscoveryCoordinator else { return [] }
                return await coord.search(query)
            },
            catalogue: { [weak self] in
                guard let self else { return [] }
                do {
                    let raw = try await self.imageService.getImages()
                    return raw.map { (id: $0.id, types: $0.types) }
                } catch {
                    // Catalogue endpoint flaky: derive a
                    // synthetic catalogue from the cached
                    // manifests. Loses the `types` info (we
                    // don't store image type per manifest), so
                    // type-filtered queries silently match
                    // nothing — acceptable degraded mode, the
                    // alternative is failing the whole call.
                    let ids = await self.imageDiscoveryCoordinator?.knownImages() ?? []
                    return ids.map { (id: $0, types: []) }
                }
            },
            discoveredIDs: { [weak self] in
                await self?.imageDiscoveryCoordinator?.knownImages() ?? []
            },
            searchPartial: { [weak self] query, minScore, limit in
                guard let coord = await self?.imageDiscoveryCoordinator else { return [] }
                return await coord.searchPartial(query, minScore: minScore, limit: limit)
            }
        )
    }

    func makeListProbeFailuresTool() -> ListProbeFailuresTool {
        ListProbeFailuresTool(snapshot: { [weak self] in
            guard let coordinator = await self?.imageDiscoveryCoordinator else { return [] }
            let iso = ISO8601DateFormatter()
            var failures: [ListProbeFailuresTool.Output.Failure] = []
            for id in await coordinator.knownImages() {
                if case .failure(let imageID, let category, let message, let attemptedAt, let jobID)
                    = await coordinator.outcome(for: id) {
                    failures.append(.init(
                        imageID: imageID,
                        category: category.rawValue,
                        message: message,
                        attemptedAtISO: iso.string(from: attemptedAt),
                        jobID: jobID))
                }
            }
            return failures
        })
    }

    func makeGetProbeLogsTool() -> GetProbeLogsTool {
        GetProbeLogsTool(fetch: { [weak self] jobID in
            guard let coordinator = await self?.imageDiscoveryCoordinator else {
                throw ToolFailureReason.authRequired
            }
            // Logs and events are independent fetches; run them together.
            async let logs = coordinator.fetchLogs(jobID: jobID)
            async let events = coordinator.fetchEvents(jobID: jobID)
            return (logs: try await logs, events: try await events)
        })
    }

    func makeGetImageManifestTool() -> GetImageManifestTool {
        GetImageManifestTool(lookup: { [weak self] image in
            guard let coordinator = await self?.imageDiscoveryCoordinator else { return nil }
            guard case .success(let manifest) = await coordinator.outcome(for: image) else {
                return nil
            }
            let iso = ISO8601DateFormatter()
            return GetImageManifestTool.Output(
                imageID: manifest.imageID,
                capturedAtISO: iso.string(from: manifest.capturedAt),
                contentHash: manifest.contentHash,
                osFamily: manifest.osFamily,
                osVersion: manifest.osVersion,
                kernel: manifest.kernel,
                dpkgCount: manifest.dpkgPackages.count,
                rpmCount: manifest.rpmPackages.count,
                apkCount: manifest.apkPackages.count,
                pythonCount: manifest.pythonPackages.count,
                rCount: manifest.rPackages.count,
                condaEnvNames: manifest.condaEnvs.map(\.name))
        })
    }
}
