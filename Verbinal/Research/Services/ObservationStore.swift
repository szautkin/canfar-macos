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
    private let fileName: String
    private(set) var observations: [DownloadedObservation] = []

    /// Observations grouped by collection.
    var groupedByCollection: [String: [DownloadedObservation]] {
        Dictionary(grouping: observations, by: \.collection)
    }

    init(fileName: String = "downloaded_observations.json") {
        self.fileName = fileName
        observations = readFromDisk()
        // Validate file existence on load
        observations = observations.filter { $0.fileExists }
        writeToDisk()
    }

    func save(_ observation: DownloadedObservation) {
        // Dedup by publisherID
        if let idx = observations.firstIndex(where: { $0.publisherID == observation.publisherID }) {
            observations[idx] = observation
        } else {
            observations.insert(observation, at: 0)
        }
        writeToDisk()
    }

    func remove(_ observation: DownloadedObservation) {
        observations.removeAll { $0.id == observation.id }
        writeToDisk()
    }

    func clear() {
        observations.removeAll()
        writeToDisk()
    }

    func contains(publisherID: String) -> Bool {
        observations.contains { $0.publisherID == publisherID }
    }

    func updateFileSize(_ observation: DownloadedObservation, size: Int64) {
        if let idx = observations.firstIndex(where: { $0.id == observation.id }) {
            observations[idx].fileSize = size
            writeToDisk()
        }
    }

    // MARK: - Persistence

    private var fileURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    private func readFromDisk() -> [DownloadedObservation] {
        guard let url = fileURL else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([DownloadedObservation].self, from: data)
        } catch {
            Self.logger.warning("Read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func writeToDisk() {
        guard let url = fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(observations)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
