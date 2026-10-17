// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
@testable import Verbinal

/// Plan 45 F2, F3: each item carries its history; this device's copy, its
/// base and storage's decide — never a clock — and every write is checked.
final class SyncByRevisionTests: XCTestCase {
    typealias FakeVOSpace = StorageSyncTests.FakeVOSpace
    typealias FakeResearch = StorageSyncTests.FakeResearch

    private var directory: URL!
    private let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
    private var path: String { ".verbinal/research/" + ResearchItem.fileName(for: key) }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("by-revision-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func sync(_ remote: FakeVOSpace, _ research: FakeResearch, _ device: String) -> StorageSync {
        StorageSync(remote: remote, catalog: StorageKindCatalog(kinds: [
            CollectionKind(id: "research", defaultFolder: ".verbinal/research", collection: research),
        ]), stateFile: directory.appendingPathComponent("state-\(device).json"))
    }

    private func remote() async -> FakeVOSpace {
        let remote = FakeVOSpace()
        let manifest = #"{ "format": "verbinal.vospace-manifest", "version": 1, "kinds": { "research": { "folder": ".verbinal/research", "format": 1, "since": "2026-10-17T12:00:00Z" } } }"#
        await remote.put(StorageManifest.path, Data(manifest.utf8))
        return remote
    }

    private func item(note: String = "first", rating: Int = 3, tags: [String] = ["usable"], at seconds: TimeInterval = 100) -> ResearchItem {
        ResearchItem(recordKey: key, changedAt: Date(timeIntervalSince1970: seconds),
                     details: .init(publisherID: key, collection: "CFHT", observationID: "1525350", targetName: "M31",
                                    instrument: "MegaPrime", filter: "r", ra: "", dec: "", startDate: "", calLevel: "2"),
                     note: .init(text: note, rating: rating, tags: tags))
    }

    private func stored(_ remote: FakeVOSpace) async throws -> (item: ResearchItem, revision: SyncRevision) {
        let item = try ResearchItem.decode(try await remote.read(path))
        return (item, SyncRevision(of: item))
    }

    /// Two devices, both synced once with the record.
    private func twoDevices() async -> (FakeVOSpace, FakeResearch, StorageSync, FakeResearch, StorageSync) {
        let remote = await remote()
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item())
        let syncA = sync(remote, a, "a"), syncB = sync(remote, b, "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        return (remote, a, syncA, b, syncB)
    }

    // MARK: - The history an item carries

    func testEachWriteSaysItsRevisionWhatItWasMadeFromAndWhoWroteIt() async throws {
        let (remote, _, _, b, syncB) = await twoDevices()
        let first = try await stored(remote).revision
        XCTAssertEqual(first.rev, 1)
        XCTAssertEqual(first.base, 0)
        XCTAssertNotNil(first.device)

        await b.set(item(note: "from B"))
        await syncB.sync(.changed)
        let second = try await stored(remote)
        XCTAssertEqual(second.revision.rev, 2)
        XCTAssertEqual(second.revision.base, 1)
        XCTAssertEqual(second.revision.baseHash, first.hash, "made from revision 1, as it said")
        XCTAssertNotEqual(second.revision.device, first.device, "another device wrote it")
        XCTAssertEqual(second.revision.hash, second.item.content)
    }

    /// Plan 44's files, written before revisions, are revision 0.
    func testAFileWithoutAHistoryIsRevisionZero() async throws {
        let remote = await remote()
        await remote.put(path, item(note: "from before").encoded())
        let here = FakeResearch()
        let storage = sync(remote, here, "a")
        await storage.sync(.signedIn)
        let taken = await here.records[key]?.note?.text
        XCTAssertEqual(taken, "from before")
        await here.set(item(note: "changed here"))
        await storage.sync(.changed)
        let written = try await stored(remote).revision
        XCTAssertEqual(written.rev, 1)
        XCTAssertEqual(written.base, 0)
    }

    // MARK: - Decided 2: different fields merge

    func testDifferentFieldsChangedOnTwoDevicesBothStay() async throws {
        let (_, a, syncA, b, syncB) = await twoDevices()
        await a.set(item(rating: 5))
        await b.set(item(tags: ["usable", "candidate"]))
        await syncA.sync(.changed)
        await syncB.sync(.changed)
        await syncA.sync(.asked)
        for research in [a, b] {
            let note = await research.records[key]?.note
            XCTAssertEqual(note?.rating, 5)
            XCTAssertEqual(note?.tags, ["usable", "candidate"])
        }
        let askedA = await syncA.status().conflicts, askedB = await syncB.status().conflicts
        let asked = askedA + askedB
        XCTAssertTrue(asked.isEmpty, "nothing to choose")
    }

    // MARK: - Decided 3: a change wins over a removal, and the person is told

    func testRemovedThereChangedHereKeepsTheChange() async throws {
        let (_, a, syncA, b, syncB) = await twoDevices()
        await a.drop(key)
        await syncA.sync(.changed)
        await b.set(item(note: "changed on B"))
        await syncB.sync(.changed)
        let onB = await b.records[key]?.note?.text
        XCTAssertEqual(onB, "changed on B", "kept")
        let told = await syncB.status().conflicts
        XCTAssertEqual(told.map(\.reason), [.removedThere])
        await syncA.sync(.asked)
        let backOnA = await a.records[key]?.note?.text
        XCTAssertEqual(backOnA, "changed on B", "and back on A, with the change")
    }

    func testRemovedHereChangedThereBringsItBack() async throws {
        let (_, a, syncA, b, syncB) = await twoDevices()
        await b.set(item(note: "changed on B"))
        await syncB.sync(.changed)
        await a.drop(key)
        await syncA.sync(.changed)
        let onA = await a.records[key]?.note?.text
        XCTAssertEqual(onA, "changed on B", "brought back")
        let told = await syncA.status().conflicts
        XCTAssertEqual(told.map(\.reason), [.removedHere])
    }

    func testARemovalOfWhatDidNotChangeGoesEverywhere() async throws {
        let (remote, a, syncA, b, syncB) = await twoDevices()
        await a.drop(key)
        await syncA.sync(.changed)
        let mark = try await stored(remote)
        XCTAssertNotNil(mark.item.removedAt)
        XCTAssertEqual(mark.revision.rev, 2)
        await syncB.sync(.asked)
        let gone = await b.records[key]
        XCTAssertNil(gone)
    }

    // MARK: - A new device

    func testANewDeviceGetsEverythingAndSendsWhatOnlyItHas() async throws {
        let (remote, _, _, _, _) = await twoDevices()
        let other = "ivo://cadc.nrc.ca/CFHT?2388466/2388466p"
        let fresh = FakeResearch()
        var own = item(note: "only on C")
        own.recordKey = other
        own.details.publisherID = other
        await fresh.set(own)
        await sync(remote, fresh, "c").sync(.signedIn)
        let keys = await fresh.records.keys.sorted()
        XCTAssertEqual(keys, [other, key].sorted())
        let sent = await remote.files.keys.contains(".verbinal/research/" + ResearchItem.fileName(for: other))
        XCTAssertTrue(sent)
    }

    // MARK: - Checked writes (F3)

    /// Both read revision 1 and both wrote 2; the other's landed after this
    /// device read its own back. Seen at the next sync — the same revision,
    /// another device's — this device's change is merged, not lost.
    func testAWriteTakenOverUnseenIsMergedAtTheNextSync() async throws {
        let (remote, a, syncA, _, _) = await twoDevices()
        await a.set(item(rating: 5))
        await syncA.sync(.changed)
        let mine = try await stored(remote)
        XCTAssertEqual(mine.revision.rev, 2)

        // Another device, from revision 1, writes revision 2 over it.
        let theirs = item(tags: ["usable", "candidate"])
        let sibling = SyncRevision(rev: 2, base: 1, baseHash: nil, device: "other", deviceName: "Other Mac", hash: theirs.content)
        await remote.put(path, CollectionSync.encoded(theirs, with: sibling))

        await syncA.sync(.asked)
        let merged = try await stored(remote)
        XCTAssertEqual(merged.item.note?.rating, 5, "this device's change, back in")
        XCTAssertEqual(merged.item.note?.tags, ["usable", "candidate"], "with the other's")
        XCTAssertEqual(merged.revision.rev, 3)
        let onA = await a.records[key]?.note
        XCTAssertEqual(onA?.rating, 5)
        XCTAssertEqual(onA?.tags, ["usable", "candidate"])
    }

    // MARK: - The person's choice

    func testThePersonsChoiceGoesEverywhere() async throws {
        let (_, a, syncA, b, syncB) = await twoDevices()
        await b.set(item(note: "from B"))
        await syncB.sync(.changed)
        await a.set(item(note: "from A"))
        await syncA.sync(.changed)
        let found = await syncA.status().conflicts.first
        let conflict = try XCTUnwrap(found)
        XCTAssertEqual(conflict.otherDevice, Host.current().localizedName, "says which device")

        await syncA.resolve(conflict.id, choosing: .mine)
        let chosen = await a.records[key]?.note?.text
        XCTAssertEqual(chosen, "from A")
        let left = await syncA.status().conflicts
        XCTAssertTrue(left.isEmpty, "not asked again")
        await syncA.sync(.changed)
        await syncB.sync(.asked)
        let onB = await b.records[key]?.note?.text
        XCTAssertEqual(onB, "from A", "and every device has it")
    }
}
