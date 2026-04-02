// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Cache wrapper for data train rows with a timestamp.
private struct DataTrainCache: Codable {
    let rows: [DataTrainRow]
    let fetchedAt: Date
}

/// Service for fetching data train enumeration values from CADC, with disk caching.
actor DataTrainService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "DataTrain")
    private let tapClient: TAPClient
    private static let cacheFileName = "datatrain_cache.json"
    private static let cacheMaxAge: TimeInterval = 24 * 3600 // 24 hours

    init(tapClient: TAPClient) {
        self.tapClient = tapClient
    }

    /// Load data train rows: returns cached data if available, fetches fresh if not.
    /// Returns (rows, wasCached) — caller can decide whether to background-refresh.
    func loadCachedOrFetch() async throws -> (rows: [DataTrainRow], wasCached: Bool) {
        if let cached = readCache() {
            return (cached.rows, true)
        }
        let rows = try await fetchFromNetwork()
        return (rows, false)
    }

    /// Fetch fresh data from network and update the disk cache.
    func fetchFresh() async throws -> [DataTrainRow] {
        return try await fetchFromNetwork()
    }

    /// Check if the cache is older than maxAge.
    func isCacheStale() -> Bool {
        guard let cached = readCache() else { return true }
        return Date().timeIntervalSince(cached.fetchedAt) > Self.cacheMaxAge
    }

    /// The timestamp of the last cache write.
    func cacheTimestamp() -> Date? {
        readCache()?.fetchedAt
    }

    // MARK: - Private

    private func fetchFromNetwork() async throws -> [DataTrainRow] {
        let adql = """
            SELECT energy_emBand, collection, instrument_name, \
            energy_bandpassName, calibrationLevel, dataProductType, type \
            FROM caom2.enumfield \
            ORDER BY energy_emBand, collection, instrument_name, \
            energy_bandpassName, calibrationLevel, dataProductType, type
            """

        let (_, rows) = try await tapClient.tapQueryRows(adql: adql)

        let dataRows = rows.map { row in
            DataTrainRow(values: Array(row.prefix(7)), fresh: true)
        }

        writeCache(DataTrainCache(rows: dataRows, fetchedAt: Date()))
        Self.logger.info("Fetched \(dataRows.count) data train rows from network")
        return dataRows
    }

    // MARK: - Disk Cache

    private var cacheURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.cacheFileName)
    }

    private func readCache() -> DataTrainCache? {
        guard let url = cacheURL else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DataTrainCache.self, from: data)
        } catch {
            return nil
        }
    }

    private func writeCache(_ cache: DataTrainCache) {
        guard let url = cacheURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.warning("Cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
