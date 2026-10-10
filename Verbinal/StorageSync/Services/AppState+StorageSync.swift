// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension AppState {
    /// The storage sync, given what it needs of the app (plan 34 V).
    func startStorageSync() {
        let remoteCompute = remoteCompute
        storageSync.signedIn(username: username, .init(
            vospace: VOSpaceBrowserService(network: network, endpoints: endpoints),
            work: workCollections(username: username),
            importManifest: { [weak self] data in
                guard let coordinator = await MainActor.run(body: { self?.imageDiscoveryCoordinator }) else { return false }
                return await coordinator.importManifest(data)
            },
            resumeRuns: { await remoteCompute.resumeWatching() }))
    }

    /// The person's work, each collection from its area (plan 36 3.1–3.6),
    /// in the order of `StorageKindCatalog.work`.
    func workCollections(username: String) -> [WorkCollection] {
        [
            researchModel.syncCollection(),
            marks.syncCollection(),
            fitsBookmarks.syncCollection(),
            workflowStore.syncCollection(),
            searchModel.savedQueryStore.syncCollection(),
            searchModel.recentSearchStore.syncCollection(),
            aiGuideService.syncCollection(instructions: sessionApprovals),
            remoteCompute.runs.syncCollection(),
            jobHistory.syncCollection(),
            userImages.syncCollection(),
            recentLaunchStore.syncCollection(),
            portalSettingsService.syncCollection(username: username),
            // Not a collection: the results kept on the Mac, sent when chosen (plan 36 4.1).
            WorkCollection(kind: ResultsKind(send: { await ResultDestination.shared.sendWaiting() }),
                           watch: { _ = ResultDestination.shared.waiting }),
        ]
    }
}
