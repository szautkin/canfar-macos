// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
import VerbinalKit
@testable import Verbinal

/// Plan 34 V: a manifest in VOSpace declares the kinds of Verbinal's data
/// kept there; the sync reads it only when it changed, lists each kind's
/// folder once, and hands each kind what changed — never deleting.
final class StorageSyncTests: XCTestCase {

    /// A VOSpace in memory: files with their dates, and who read what.
    actor FakeVOSpace: StorageRemote {
        private(set) var files: [String: (data: Data, modified: Date)] = [:]
        private(set) var folders: Set<String> = []
        private(set) var reads: [String] = []
        private(set) var lists: [String] = []
        var publicFolders: Set<String> = []
        var failing = false
        private var clock = Date(timeIntervalSince1970: 1_800_000_000)

        func put(_ path: String, _ data: Data) {
            clock = clock.addingTimeInterval(1)
            files[path] = (data, clock)
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty { folders.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        func makeFolder(_ path: String) { folders.insert(path) }
        func setPublic(_ folder: String) { publicFolders.insert(folder) }
        func setFailing(_ value: Bool) { failing = value }
        func forgetCounts() { reads = []; lists = [] }

        func list(_ folder: String) async throws -> [StorageItem]? {
            if failing { throw URLError(.notConnectedToInternet) }
            lists.append(folder)
            guard folders.contains(folder) else { return nil }
            let prefix = folder + "/"
            var items: [StorageItem] = []
            for (path, file) in files where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
                items.append(StorageItem(name: String(path.dropFirst(prefix.count)), size: Int64(file.data.count),
                                         modified: file.modified, isFolder: false))
            }
            for sub in folders where sub.hasPrefix(prefix) && !sub.dropFirst(prefix.count).contains("/") {
                items.append(StorageItem(name: String(sub.dropFirst(prefix.count)), size: nil, modified: nil, isFolder: true))
            }
            return items
        }
        func read(_ path: String) async throws -> Data {
            if failing { throw URLError(.notConnectedToInternet) }
            reads.append(path)
            guard let file = files[path] else { throw URLError(.fileDoesNotExist) }
            return file.data
        }
        func write(_ data: Data, to path: String) async throws {
            if failing { throw URLError(.notConnectedToInternet) }
            put(path, data)
        }
        func isPublic(_ folder: String) async throws -> Bool { publicFolders.contains(folder) }
        func text(_ path: String) -> String? { files[path].map { String(decoding: $0.data, as: UTF8.self) } }
    }

    /// Research on one device, in memory.
    actor FakeResearch: ResearchSyncSource {
        private(set) var records: [String: ResearchItem] = [:]
        private(set) var replacedOnes: [ResearchItem] = []
        func items() async -> [ResearchItem] { Array(records.values) }
        func apply(_ item: ResearchItem) async { var kept = item; kept.removedAt = nil; records[item.recordKey] = kept }
        func remove(recordKey: String) async { records.removeValue(forKey: recordKey) }
        func replaced(_ item: ResearchItem, by newer: ResearchItem) async { replacedOnes.append(item) }
        func set(_ item: ResearchItem) { records[item.recordKey] = item }
        func drop(_ key: String) { records.removeValue(forKey: key) }
    }

    private final class Imports: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Data] = []
        func add(_ data: Data) { lock.withLock { list.append(data) } }
        var count: Int { lock.withLock { list.count } }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("storage-sync-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func sync(_ remote: FakeVOSpace, research: FakeResearch = FakeResearch(), imports: Imports = Imports(),
                      device: String = "mac") -> StorageSync {
        let catalog = StorageKindCatalog(kinds: [
            ResearchKind(source: research),
            ImagePackagesKind(importManifest: { imports.add($0); return true }),
            ComputeRunsKind(resume: {}),
            CountedKind.stagedScripts,
            CountedKind.exports,
        ])
        return StorageSync(remote: remote, catalog: catalog,
                           stateFile: directory.appendingPathComponent("state-\(device).json"))
    }

    private func manifest(_ kinds: [String: String], extra: String = "") -> Data {
        let entries = kinds.map { #""\#($0.key)": { "folder": "\#($0.value)", "format": 1, "since": "2026-10-08T12:00:00Z" }"# }
        return Data(#"{ "format": "verbinal.vospace-manifest", "version": 1, \#(extra) "kinds": { \#(entries.joined(separator: ", ")) } }"#.utf8)
    }

    private func item(_ key: String, note: String, at seconds: TimeInterval) -> ResearchItem {
        ResearchItem(recordKey: key, changedAt: Date(timeIntervalSince1970: seconds),
                     details: .init(publisherID: key, collection: "CFHT", observationID: "1525350", targetName: "M31",
                                    instrument: "MegaPrime", filter: "r", ra: "", dec: "", startDate: "", calLevel: "2"),
                     note: .init(text: note, rating: 3, tags: ["usable"]))
    }

    // MARK: - The manifest

    func testAnUnchangedManifestIsNotReadAgain() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["imagePackages": ".verbinal/manifests"]))
        await remote.makeFolder(".verbinal/manifests")
        let storage = sync(remote)
        await storage.sync(.signedIn)
        let firstReads = await remote.reads
        XCTAssertEqual(firstReads, [StorageManifest.path])

        await remote.forgetCounts()
        await storage.sync(.asked)
        let reads = await remote.reads, lists = await remote.lists
        XCTAssertEqual(reads, [], "nothing changed: nothing read")
        XCTAssertEqual(lists, [".verbinal", ".verbinal/manifests"], "one listing of .verbinal, one of each declared kind")
        let status = await storage.status()
        XCTAssertTrue(status.hasManifest)
        XCTAssertEqual(status.kinds.filter(\.declared).map(\.id), ["imagePackages"])
    }

    func testNoManifestDeclaresTheKindsWhoseFoldersAreThereButNotResearch() async throws {
        let remote = FakeVOSpace()
        await remote.makeFolder(".verbinal")
        await remote.makeFolder(".verbinal/manifests")
        await remote.makeFolder(".verbinal/research")
        await remote.makeFolder("Verbinal-Exports")
        await sync(remote).sync(.signedIn)
        let written = try StorageManifest.decode(try await remote.read(StorageManifest.path))
        XCTAssertEqual(Set(written.kinds.keys), ["imagePackages", "exports"], "research waits for the person")

        let empty = FakeVOSpace()
        await sync(empty).sync(.signedIn)
        let files = await empty.files
        XCTAssertTrue(files.isEmpty, "no Verbinal data: no manifest, no folder")
    }

    func testUnknownKindsAndFieldsSurviveAWrite() async throws {
        let remote = FakeVOSpace()
        let original = manifest(["imagePackages": ".verbinal/manifests", "linuxNotebooks": "notebooks"],
                                extra: #""writtenBy": "Verbinal for Linux","#)
        await remote.put(StorageManifest.path, original)
        let storage = sync(remote)
        await storage.sync(.signedIn)
        try await storage.setDeclared("research", true)

        let text = await remote.text(StorageManifest.path) ?? ""
        let written = try StorageManifest.decode(Data(text.utf8))
        XCTAssertEqual(written.kinds["linuxNotebooks"]?.folder, "notebooks", "another app's kind is kept")
        XCTAssertTrue(text.contains("Verbinal for Linux"), "and its fields")
        XCTAssertTrue(written.declares("research"))
        XCTAssertFalse(text.contains("bookmark") || text.contains("/Users/"), "folder names and dates only")

        try await storage.setDeclared("research", false)
        let after = try StorageManifest.decode(try await remote.read(StorageManifest.path))
        XCTAssertFalse(after.declares("research"))
        XCTAssertTrue(after.declares("linuxNotebooks"))
    }

    func testANewerFormatOfAKindIsLeftAsItIs() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, Data(#"{ "format": "verbinal.vospace-manifest", "version": 1, "kinds": { "imagePackages": { "folder": ".verbinal/manifests", "format": 2, "since": "2026-10-08T12:00:00Z" } } }"#.utf8))
        await remote.put(".verbinal/manifests/a.json", Data("{}".utf8))
        let imports = Imports()
        let storage = sync(remote, imports: imports)
        await storage.sync(.signedIn)
        XCTAssertEqual(imports.count, 0)
        let note = await storage.status().kinds.first { $0.id == "imagePackages" }?.note
        XCTAssertTrue(note?.contains("newer Verbinal") == true, note ?? "")
        XCTAssertThrowsError(try StorageManifest.decode(Data(#"{ "format": "verbinal.vospace-manifest", "version": 9, "kinds": {} }"#.utf8)))
    }

    // MARK: - The kinds

    func testAPackageListIsImportedOnceUntilItChanges() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["imagePackages": ".verbinal/manifests"]))
        await remote.put(".verbinal/manifests/images.canfar.net_skaha_astroml_24.07.json", Data("one".utf8))
        let imports = Imports()
        let storage = sync(remote, imports: imports)
        await storage.sync(.signedIn)
        XCTAssertEqual(imports.count, 1)
        await storage.sync(.asked)
        XCTAssertEqual(imports.count, 1, "unchanged: not read again")
        await remote.put(".verbinal/manifests/images.canfar.net_skaha_astroml_24.07.json", Data("two".utf8))
        await storage.sync(.asked)
        XCTAssertEqual(imports.count, 2)
    }

    func testScriptsAndExportsAreCountedNeverDeleted() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["stagedScripts": ".verbinal-scripts", "exports": "Verbinal-Exports"]))
        await remote.put(".verbinal-scripts/a.py", Data("print(1)".utf8))
        await remote.put("Verbinal-Exports/bundle.zip", Data(count: 100))
        let storage = sync(remote)
        await storage.sync(.signedIn)
        let kinds = await storage.status().kinds
        XCTAssertEqual(kinds.first { $0.id == "stagedScripts" }?.items, 1)
        XCTAssertEqual(kinds.first { $0.id == "exports" }?.bytes, 100)
        let files = await remote.files
        XCTAssertEqual(files.count, 3, "nothing deleted")
    }

    // MARK: - Research

    func testANoteMadeOnOneDeviceAppearsOnTheOther() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        let mine = FakeResearch(), theirs = FakeResearch()
        await mine.set(item("ivo://cadc.nrc.ca/CFHT?1525350/1525350p", note: "seeing 0.6", at: 100))
        await sync(remote, research: mine, device: "a").sync(.signedIn)
        await sync(remote, research: theirs, device: "b").sync(.signedIn)
        let arrived = await theirs.records["ivo://cadc.nrc.ca/CFHT?1525350/1525350p"]
        XCTAssertEqual(arrived?.note?.text, "seeing 0.6")
        let stored = await remote.text(".verbinal/research/" + ResearchItem.fileName(for: "ivo://cadc.nrc.ca/CFHT?1525350/1525350p")) ?? ""
        XCTAssertFalse(stored.contains("localPath") || stored.contains("bookmark"), "nothing of this Mac")
    }

    func testTheNewerOfTwoChangesWinsAndTheOtherIsKept() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item(key, note: "first", at: 100))
        let syncA = sync(remote, research: a, device: "a"), syncB = sync(remote, research: b, device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        // Both change it; B's is newer.
        await a.set(item(key, note: "from A", at: 200))
        await b.set(item(key, note: "from B", at: 300))
        await syncB.sync(.changed)
        await syncA.sync(.changed)
        let onA = await a.records[key]?.note?.text
        XCTAssertEqual(onA, "from B", "the newer wins")
        let replaced = await a.replacedOnes.map { $0.note?.text }
        XCTAssertEqual(replaced, ["from A"], "and the one it replaced is kept")
    }

    func testARemovalTravelsAsAMarkAndAMissingItemRemovesNothing() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
        let other = "ivo://cadc.nrc.ca/CFHT?2388466/2388466p"
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item(key, note: "keep?", at: 100))
        await a.set(item(other, note: "stays", at: 100))
        let syncA = sync(remote, research: a, device: "a"), syncB = sync(remote, research: b, device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        let both = await b.records.count
        XCTAssertEqual(both, 2)

        await a.drop(key)
        await syncA.sync(.changed)
        let mark = try ResearchItem.decode(try await remote.read(".verbinal/research/" + ResearchItem.fileName(for: key)))
        XCTAssertNotNil(mark.removedAt, "a mark, not a deletion")
        await syncB.sync(.asked)
        let left = await b.records.keys.sorted()
        XCTAssertEqual(left, [other])

        // A device that never had a record does not mark it removed.
        let c = FakeResearch()
        await sync(remote, research: c, device: "c").sync(.signedIn)
        let stillThere = try ResearchItem.decode(try await remote.read(".verbinal/research/" + ResearchItem.fileName(for: other)))
        XCTAssertNil(stillThere.removedAt)
    }

    func testResearchIsNotSyncedWhileTheFolderIsPublic() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        await remote.setPublic(".verbinal")
        let a = FakeResearch()
        await a.set(item("ivo://cadc.nrc.ca/CFHT?1525350/1525350p", note: "private words", at: 100))
        let storage = sync(remote, research: a)
        await storage.sync(.signedIn)
        let files = await remote.files.keys.filter { $0.contains("research") }
        XCTAssertTrue(files.isEmpty, "nothing sent")
        let note = await storage.status().kinds.first { $0.id == "research" }?.note
        XCTAssertEqual(note, ResearchKind.publicNote)
    }

    // MARK: - The sync

    func testFailuresMakeAutomaticSyncsWaitButNotOneAskedFor() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["exports": "Verbinal-Exports"]))
        await remote.setFailing(true)
        let storage = sync(remote)
        await storage.sync(.signedIn)
        var status = await storage.status()
        XCTAssertNotNil(status.lastFailure)
        await remote.setFailing(false)
        await remote.forgetCounts()
        await storage.sync(.cameBack)
        let skipped = await remote.lists
        XCTAssertEqual(skipped, [], "an automatic sync waits after a failure")
        await storage.sync(.asked)
        status = await storage.status()
        XCTAssertNil(status.lastFailure, "one asked for runs")
    }

    func testNothingRunsAfterSignOut() async throws {
        let remote = FakeVOSpace()
        let storage = sync(remote)
        await storage.stop()
        await storage.sync(.asked)
        let lists = await remote.lists
        XCTAssertEqual(lists, [])
    }

    /// The guardrail: the catalogue lists every kind the order names, each
    /// with its title for the person.
    @MainActor
    func testTheCatalogueListsEveryKind() {
        let catalog = StorageSyncModel.catalog(.init(
            vospace: VOSpaceBrowserService(network: NetworkClient()),
            research: ObservationStore(fileName: "unused-\(UUID().uuidString).json", spotlight: nil),
            notes: ObservationNoteStore(database: try! AppDatabase.makeInMemory(), legacyNotesSource: nil),
            importManifest: { _ in false }, resumeRuns: {}))
        XCTAssertEqual(catalog.kinds.map(\.id).sorted(), StorageKindCatalog.order.sorted())
        for id in StorageKindCatalog.order {
            XCTAssertNotEqual(StorageSettingsTab.title(id), id, "\(id) has a title")
        }
    }
}
