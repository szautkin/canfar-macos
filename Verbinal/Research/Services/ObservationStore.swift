// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

/// Persists metadata for downloaded observations.
@Observable
@MainActor
final class ObservationStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ObservationStore")
    private let persistence: DiskPersistence<[DownloadedObservation]>
    /// Spotlight indexer — every save/remove fans out so the user can find
    /// their downloaded observations from the macOS Spotlight bar by target
    /// name, collection, instrument, etc. Optional so unit tests can opt out.
    private let spotlight: ObservationSpotlightIndexer?
    private(set) var observations: [DownloadedObservation] = []

    init(
        fileName: String = "downloaded_observations.json",
        spotlight: ObservationSpotlightIndexer? = ObservationSpotlightIndexer()
    ) {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        self.spotlight = spotlight
        // File existence is surfaced via DownloadedObservation.fileExists — do not prune on load.
        // Pruning on launch would silently destroy metadata for files on remounted/offline volumes.
        self.observations = persistence.read() ?? []
        // Refresh the Spotlight index off-disk on launch so coverage stays
        // current across schema changes / out-of-process index loss.
        if !observations.isEmpty {
            spotlight?.reindexAll(observations)
        }
    }

    /// Keeps `observation`, replacing Research's record of the same
    /// publisher ID — as the same record (its id), so a download into a
    /// record without a file, or a re-download, is still the record an
    /// agent or a link knows. Returns what is stored.
    @discardableResult
    func save(_ observation: DownloadedObservation) -> DownloadedObservation {
        var stored = observation
        if let idx = observations.firstIndex(where: { $0.publisherID == observation.publisherID }) {
            stored.id = observations[idx].id
            observations[idx] = stored
        } else {
            observations.insert(stored, at: 0)
        }
        persistence.write(observations)
        spotlight?.index(stored)
        return stored
    }

    /// Keeps an observation without its file. One Research already has is
    /// left as it is. Returns the record, and whether it is new.
    func keep(_ observation: DownloadedObservation) -> (record: DownloadedObservation, added: Bool) {
        if let existing = observations.first(where: { $0.publisherID == observation.publisherID }) {
            return (existing, false)
        }
        return (save(observation.withoutFile()), true)
    }

    /// Forgets a record's file (the caller deletes it), keeping the
    /// observation. Nil when the id is not in Research.
    @discardableResult
    func forgetFile(of id: UUID) -> DownloadedObservation? {
        guard let idx = observations.firstIndex(where: { $0.id == id }) else { return nil }
        observations[idx] = observations[idx].withoutFile()
        persistence.write(observations)
        spotlight?.index(observations[idx])
        return observations[idx]
    }

    func remove(_ observation: DownloadedObservation) {
        observations.removeAll { $0.id == observation.id }
        persistence.write(observations)
        spotlight?.deindex(observation)
    }

    func clear() {
        observations.removeAll()
        persistence.write(observations)
        spotlight?.deindexAll()
    }

    func contains(publisherID: String) -> Bool {
        observations.contains { $0.publisherID == publisherID }
    }

    /// Re-read the persisted archive. MCP tools and the Research UI
    /// must see ids downloaded in a previous session (or by the other
    /// store instance before they were unified).
    @discardableResult
    func reload() -> [DownloadedObservation] {
        observations = persistence.read() ?? observations
        return observations
    }

    /// Look up by id, reloading from disk once on a miss so a stale
    /// in-memory snapshot doesn't report `unknownTarget` for an archive
    /// row that `list_downloaded_observations` (or the UI) already shows.
    func observation(id: UUID) -> DownloadedObservation? {
        if let hit = observations.first(where: { $0.id == id }) { return hit }
        reload()
        return observations.first(where: { $0.id == id })
    }

    /// Resolve a downloaded-observation id from a full UUID (with or
    /// without hyphens) or a unique 8+ hex prefix. Agents often paste
    /// the truncated form from logs (`966B5ED7`). Ambiguous prefixes
    /// return nil.
    func observation(matching raw: String) -> DownloadedObservation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = Self.parseUUID(trimmed) {
            return observation(id: uuid)
        }
        let hex = trimmed.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8, hex.count < 32, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        let prefix = hex.uppercased()
        reload()
        let matches = observations.filter {
            $0.id.uuidString.replacingOccurrences(of: "-", with: "").uppercased().hasPrefix(prefix)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A record by any name an agent or a person has for it: its id (or a
    /// unique 8+ hex prefix), its publisher ID, or — when only one record
    /// has it — its observation ID.
    func record(identifiedBy raw: String) -> DownloadedObservation? {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let byID = observation(matching: wanted) { return byID }
        if let byPublisher = observations.first(where: { $0.publisherID == wanted }) { return byPublisher }
        let byObservation = observations.filter { $0.observationID == wanted }
        return byObservation.count == 1 ? byObservation[0] : nil
    }

    /// Canonical UUID from hyphenated or 32-char hex form.
    static func parseUUID(_ raw: String) -> UUID? {
        if let uuid = UUID(uuidString: raw) { return uuid }
        let hex = raw.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        let s = hex.uppercased()
        let i8 = s.index(s.startIndex, offsetBy: 8)
        let i12 = s.index(s.startIndex, offsetBy: 12)
        let i16 = s.index(s.startIndex, offsetBy: 16)
        let i20 = s.index(s.startIndex, offsetBy: 20)
        return UUID(uuidString: "\(s[..<i8])-\(s[i8..<i12])-\(s[i12..<i16])-\(s[i16..<i20])-\(s[i20...])")
    }
}
