// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Behaviour pinning for the Spotlight indexer + URL-roundtrip helper.
// Real `CSSearchableIndex` calls are routed through the protocol so the
// test suite never touches the macOS index — the assertions are about
// payload shape, not Spotlight integration itself.

import XCTest
import CoreSpotlight
@testable import Verbinal

final class ObservationSpotlightIndexerTests: XCTestCase {

    // MARK: - URL ↔ UUID round-trip

    func testActivityURLRoundTrip() {
        let id = UUID()
        let url = URL(string: ObservationSpotlightIndexer.activityURLPrefix + id.uuidString)!
        let parsed = ObservationSpotlightIndexer.observationID(fromActivityURL: url)
        XCTAssertEqual(parsed, id)
    }

    func testActivityURLRejectsForeignScheme() {
        let url = URL(string: "https://example.com/something")!
        XCTAssertNil(ObservationSpotlightIndexer.observationID(fromActivityURL: url))
    }

    func testActivityURLRejectsMalformedSuffix() {
        let url = URL(string: "verbinal://observation/not-a-uuid")!
        XCTAssertNil(ObservationSpotlightIndexer.observationID(fromActivityURL: url))
    }

    // MARK: - Item construction

    func testItemHasTitleSubtitleAndKeywords() {
        let indexer = ObservationSpotlightIndexer(index: SpyIndex())
        let obs = makeObservation()
        let item = indexer.makeItem(for: obs)

        XCTAssertEqual(item.uniqueIdentifier, obs.id.uuidString)
        XCTAssertEqual(item.domainIdentifier, ObservationSpotlightIndexer.domainIdentifier)
        XCTAssertEqual(item.attributeSet.title, "M31 — JWST")
        XCTAssertTrue((item.attributeSet.contentDescription ?? "").contains("jw01147"))
        XCTAssertTrue((item.attributeSet.contentDescription ?? "").contains("NIRCam"))

        let keywords = Set(item.attributeSet.keywords ?? [])
        XCTAssertTrue(keywords.contains("M31"))
        XCTAssertTrue(keywords.contains("JWST"))
        XCTAssertTrue(keywords.contains("NIRCam"))
        XCTAssertTrue(keywords.contains("F200W"))
        XCTAssertTrue(keywords.contains("jw01147"))
    }

    func testItemFallsBackToObsIDWhenTargetEmpty() {
        let indexer = ObservationSpotlightIndexer(index: SpyIndex())
        var obs = makeObservation()
        obs.targetName = ""
        obs.collection = ""
        let item = indexer.makeItem(for: obs)
        XCTAssertEqual(item.attributeSet.title, "jw01147")
    }

    func testItemSetsContentURLWhenLocalPathPresent() {
        let indexer = ObservationSpotlightIndexer(index: SpyIndex())
        let obs = makeObservation()
        let item = indexer.makeItem(for: obs)
        XCTAssertNotNil(item.attributeSet.contentURL)
        XCTAssertEqual(item.attributeSet.contentURL?.path, obs.localPath)
    }

    // MARK: - Index → store call routing

    func testIndexRoutesToInjectedIndex() {
        let spy = SpyIndex()
        let indexer = ObservationSpotlightIndexer(index: spy)
        indexer.index(makeObservation())
        XCTAssertEqual(spy.indexedItems.count, 1)
        XCTAssertEqual(spy.indexedItems.first?.uniqueIdentifier, makeObservation().id.uuidString)
    }

    func testDeindexRoutesToInjectedIndex() {
        let spy = SpyIndex()
        let indexer = ObservationSpotlightIndexer(index: spy)
        indexer.deindex(makeObservation())
        XCTAssertEqual(spy.deletedIdentifiers, [makeObservation().id.uuidString])
    }

    func testDeindexAllUsesDomainIdentifier() {
        let spy = SpyIndex()
        let indexer = ObservationSpotlightIndexer(index: spy)
        indexer.deindexAll()
        XCTAssertEqual(spy.deletedDomainIdentifiers, [ObservationSpotlightIndexer.domainIdentifier])
    }

    func testReindexAllSendsEveryObservation() {
        let spy = SpyIndex()
        let indexer = ObservationSpotlightIndexer(index: spy)
        let obs = [makeObservation(), makeObservation(idSuffix: "2", target: "M51")]
        indexer.reindexAll(obs)
        XCTAssertEqual(spy.indexedItems.count, 2)
    }

    // MARK: - Helpers

    private static let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func makeObservation(idSuffix: String = "1", target: String = "M31") -> DownloadedObservation {
        let id: UUID
        if idSuffix == "1" {
            id = Self.fixedID
        } else if let parsed = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(idSuffix)") {
            id = parsed
        } else {
            id = UUID()
        }
        return DownloadedObservation(
            id: id,
            publisherID: "ivo://cadc.nrc.ca/JWST?jw01147",
            collection: "JWST",
            observationID: "jw01147",
            targetName: target,
            instrument: "NIRCam",
            filter: "F200W",
            ra: "10.68",
            dec: "41.27",
            startDate: "59000.0",
            calLevel: "2",
            localPath: "/tmp/JWST/jw01147.fits",
            downloadedAt: Date()
        )
    }
}

// MARK: - Spy

/// In-memory `SpotlightIndex` that records every operation. Lets tests
/// assert on the items / identifiers passed in without needing the real
/// `CSSearchableIndex`.
private final class SpyIndex: SpotlightIndex, @unchecked Sendable {
    private let lock = NSLock()
    private var _indexedItems: [CSSearchableItem] = []
    private var _deletedIdentifiers: [String] = []
    private var _deletedDomainIdentifiers: [String] = []

    var indexedItems: [CSSearchableItem] {
        lock.lock(); defer { lock.unlock() }
        return _indexedItems
    }
    var deletedIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return _deletedIdentifiers
    }
    var deletedDomainIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return _deletedDomainIdentifiers
    }

    func indexSearchableItems(_ items: [CSSearchableItem],
                              completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.lock()
        _indexedItems.append(contentsOf: items)
        lock.unlock()
        completionHandler?(nil)
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.lock()
        _deletedIdentifiers.append(contentsOf: identifiers)
        lock.unlock()
        completionHandler?(nil)
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?) {
        lock.lock()
        _deletedDomainIdentifiers.append(contentsOf: domainIdentifiers)
        lock.unlock()
        completionHandler?(nil)
    }
}
