// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

/// Indexes `DownloadedObservation`s into Core Spotlight so users can find
/// their saved astronomical data by target name / collection / instrument
/// from the macOS Spotlight bar without opening the app.
///
/// Index keying: every observation has a stable `id: UUID`. We use the
/// UUID string as both the `CSSearchableItem` uniqueIdentifier and as the
/// suffix of the activity URL the system fires when the user clicks a
/// search result. The host app maps the URL back to the observation in
/// `application(_:continue:)`.
///
/// Privacy: the indexed payload is the same metadata the user sees in
/// the Research panel — collection, target, instrument, observation ID,
/// file path. No tokens, credentials, or proprietary data.
final class ObservationSpotlightIndexer: Sendable {
    /// Stable URL scheme prefix the system uses to ferry a click back to
    /// the app. Format: `verbinal://observation/{uuid}`.
    static let activityURLPrefix = "verbinal://observation/"

    /// Domain identifier — namespaces our entries away from any other
    /// item set the app might index in the future, and lets us
    /// `deleteSearchableItems(withDomainIdentifiers:)` to wipe everything
    /// at once on logout.
    static let domainIdentifier = "com.codebg.Verbinal.observations"

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Spotlight")

    /// Where to write the index. `nil` (default) hits the user's per-app
    /// index; tests inject `InMemorySpotlightIndex` to avoid touching the
    /// real index. The protocol mirrors `CSSearchableIndex`'s minimal
    /// surface so production code keeps the system path.
    private let index: SpotlightIndex

    init(index: SpotlightIndex = SystemSpotlightIndex()) {
        self.index = index
    }

    /// Insert or replace the index entry for one observation. Idempotent —
    /// reindexing the same observation just refreshes its attributes.
    func index(_ observation: DownloadedObservation) {
        let item = makeItem(for: observation)
        index.indexSearchableItems([item]) { error in
            if let error {
                Self.logger.warning("Spotlight index failed for \(observation.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Remove the index entry for one observation. Safe to call on items
    /// that aren't indexed (no-op).
    func deindex(_ observation: DownloadedObservation) {
        index.deleteSearchableItems(withIdentifiers: [observation.id.uuidString]) { error in
            if let error {
                Self.logger.warning("Spotlight deindex failed for \(observation.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Wipe the entire observation index. Called on logout so the previous
    /// user's search results don't surface for the next user on the same
    /// machine.
    func deindexAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { error in
            if let error {
                Self.logger.warning("Spotlight wipe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reindex the full observations list — useful at app launch and
    /// after schema changes that affect attribute coverage.
    func reindexAll(_ observations: [DownloadedObservation]) {
        let items = observations.map(makeItem(for:))
        index.indexSearchableItems(items) { error in
            if let error {
                Self.logger.warning("Spotlight reindex-all failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Decode the observation's UUID back from a Spotlight activity URL.
    /// Returns nil if the URL is malformed or for some unrelated scheme.
    static func observationID(fromActivityURL url: URL) -> UUID? {
        guard url.absoluteString.hasPrefix(activityURLPrefix) else { return nil }
        let suffix = String(url.absoluteString.dropFirst(activityURLPrefix.count))
        return UUID(uuidString: suffix)
    }

    // MARK: - Item construction

    /// Build the searchable-item payload for one observation.
    ///
    /// We use `kUTTypeData` as the content type so Spotlight treats this
    /// as a generic file pointer (rather than a contact or message), and
    /// fold every astronomy-relevant attribute into keywords / display
    /// strings. The user can find the row via *any* substring match —
    /// "M31", "JWST", "NIRCam", "f200w" all work.
    func makeItem(for observation: DownloadedObservation) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .data)

        // Title: target name + collection (e.g. "M31 — JWST").
        let titleParts = [observation.targetName, observation.collection]
            .filter { !$0.isEmpty }
        attrs.title = titleParts.isEmpty
            ? observation.observationID
            : titleParts.joined(separator: " — ")

        // Subtitle / description: observation ID + instrument + filter.
        let subtitleParts = [observation.observationID, observation.instrument, observation.filter]
            .filter { !$0.isEmpty }
        attrs.contentDescription = subtitleParts.joined(separator: " · ")

        // Keywords: every metadata field the user might type.
        var keywords: Set<String> = []
        for raw in [observation.targetName, observation.collection, observation.instrument,
                    observation.filter, observation.observationID] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { keywords.insert(trimmed) }
        }
        attrs.keywords = Array(keywords)

        // Provide the file URL too so Spotlight can show "Reveal in
        // Finder" / Quick Look from the result row.
        if !observation.localPath.isEmpty {
            attrs.contentURL = URL(fileURLWithPath: observation.localPath)
        }

        // Use the observation's downloadedAt as the contentCreatedDate so
        // sort-by-date in Spotlight respects when the user actually
        // downloaded it.
        attrs.contentCreationDate = observation.downloadedAt

        let item = CSSearchableItem(
            uniqueIdentifier: observation.id.uuidString,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attrs
        )
        return item
    }
}

// MARK: - Indirection (SpotlightIndex)

/// The minimal surface of `CSSearchableIndex` we depend on, abstracted
/// behind a protocol so unit tests can inject an in-memory fake instead
/// of touching the real macOS index.
protocol SpotlightIndex: Sendable {
    func indexSearchableItems(_ items: [CSSearchableItem],
                              completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteSearchableItems(withIdentifiers identifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?)
}

/// Production implementation — wraps `CSSearchableIndex.default()`.
struct SystemSpotlightIndex: SpotlightIndex {
    func indexSearchableItems(_ items: [CSSearchableItem],
                              completionHandler: (@Sendable (Error?) -> Void)?) {
        CSSearchableIndex.default().indexSearchableItems(items, completionHandler: completionHandler)
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers,
                                                          completionHandler: completionHandler)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: domainIdentifiers,
                                                          completionHandler: completionHandler)
    }
}
