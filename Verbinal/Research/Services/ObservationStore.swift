// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

/// Persists metadata for downloaded observations.
@Observable
final class ObservationStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ObservationStore")
    private let persistence: DiskPersistence<[DownloadedObservation]>
    private(set) var observations: [DownloadedObservation] = []

    /// Observations grouped by collection.
    var groupedByCollection: [String: [DownloadedObservation]] {
        Dictionary(grouping: observations, by: \.collection)
    }

    init(fileName: String = "downloaded_observations.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        // File existence is surfaced via DownloadedObservation.fileExists — do not prune on load.
        // Pruning on launch would silently destroy metadata for files on remounted/offline volumes.
        self.observations = persistence.read() ?? []
    }

    func save(_ observation: DownloadedObservation) {
        // Dedup by publisherID
        if let idx = observations.firstIndex(where: { $0.publisherID == observation.publisherID }) {
            observations[idx] = observation
        } else {
            observations.insert(observation, at: 0)
        }
        persistence.write(observations)
    }

    func remove(_ observation: DownloadedObservation) {
        observations.removeAll { $0.id == observation.id }
        persistence.write(observations)
    }

    func clear() {
        observations.removeAll()
        persistence.write(observations)
    }

    func contains(publisherID: String) -> Bool {
        observations.contains { $0.publisherID == publisherID }
    }

    func updateFileSize(_ observation: DownloadedObservation, size: Int64) {
        if let idx = observations.firstIndex(where: { $0.id == observation.id }) {
            observations[idx].fileSize = size
            persistence.write(observations)
        }
    }
}
