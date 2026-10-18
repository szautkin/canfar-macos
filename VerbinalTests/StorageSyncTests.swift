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
        /// Times with a fraction of a second, as VOSpace gives them.
        func useFractionalTimes() { clock = Date(timeIntervalSince1970: 1_800_000_000.637) }

        func put(_ path: String, _ data: Data) {
            clock = clock.addingTimeInterval(1)
            files[path] = (data, clock)
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty { folders.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        /// Another device's write, made while this one syncs: after it next
        /// lists `folder`, or once it has written `path`.
        private var afterListing: [String: [(path: String, data: Data)]] = [:]
        private var afterWriting: [String: [(path: String, data: Data)]] = [:]
        func whenListed(_ folder: String, alsoPut path: String, _ data: Data) { afterListing[folder, default: []].append((path, data)) }
        func whenWritten(_ written: String, alsoPut path: String, _ data: Data) { afterWriting[written, default: []].append((path, data)) }

        /// A listing of `folder` held open, so a sync is caught under way.
        private var holding: Set<String> = []
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        private var heldWaiters: [String: CheckedContinuation<Void, Never>] = [:]
        func hold(_ folder: String) { holding.insert(folder) }
        func release(_ folder: String) { holding.remove(folder); held.removeValue(forKey: folder)?.resume() }
        /// Returns once a sync is held at `folder`.
        func whenHeld(_ folder: String) async {
            guard held[folder] == nil else { return }
            await withCheckedContinuation { heldWaiters[folder] = $0 }
        }

        func makeFolder(_ path: String) { folders.insert(path) }
        func setPublic(_ folder: String) { publicFolders.insert(folder) }
        func setFailing(_ value: Bool) { failing = value }
        func forgetCounts() { reads = []; lists = [] }

        func list(_ folder: String) async throws -> [StorageItem]? {
            if failing { throw URLError(.notConnectedToInternet) }
            if holding.contains(folder) {
                await withCheckedContinuation { gate in
                    held[folder] = gate
                    heldWaiters.removeValue(forKey: folder)?.resume()
                }
            }
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
            for other in afterListing.removeValue(forKey: folder) ?? [] { put(other.path, other.data) }
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
            for other in afterWriting.removeValue(forKey: path) ?? [] { put(other.path, other.data) }
        }
        func isPublic(_ folder: String) async throws -> Bool { publicFolders.contains(folder) }
        var home = true
        func setHome(_ value: Bool) { home = value }
        func hasHome() async throws -> Bool { home }
        func text(_ path: String) -> String? { files[path].map { String(decoding: $0.data, as: UTF8.self) } }
    }

    /// Research on one device, in memory.
    actor FakeResearch: SyncCollection {
        private(set) var records: [String: ResearchItem] = [:]
        func items() async -> [ResearchItem] { Array(records.values) }
        func apply(_ item: ResearchItem) async { var kept = item; kept.removedAt = nil; records[item.recordKey] = kept }
        func remove(key: String) async { records.removeValue(forKey: key) }
        nonisolated func title(of item: ResearchItem) -> String { item.details.targetName }
        func set(_ item: ResearchItem) { records[item.recordKey] = item }
        func drop(_ key: String) { records.removeValue(forKey: key) }
    }

    /// The values `sync`'s device keeps waiting for the person, field by field.
    private func waiting(_ sync: StorageSync) async -> [String] {
        await sync.status().conflicts.flatMap(\.fields).compactMap { if case .string(let text)? = $0.mine { text } else { nil } }
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
                      device: String = "mac", importing: (@Sendable (Data) async -> Bool)? = nil,
                      watcher: (@Sendable (StorageSync.Event) async -> Void)? = nil) -> StorageSync {
        let catalog = StorageKindCatalog(kinds: [
            CollectionKind(id: "research", defaultFolder: ".verbinal/research", collection: research),
            ImagePackagesKind(importManifest: importing ?? { imports.add($0); return true }),
            ComputeRunsKind(resume: {}),
            CountedKind.stagedScripts,
            CountedKind.exports,
        ])
        return StorageSync(remote: remote, catalog: catalog,
                           stateFile: directory.appendingPathComponent("state-\(device).json"), watcher: watcher)
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

    /// Plan 40 A: the manifest was written for a collection before any probe
    /// made `.verbinal/manifests`; a second device would never have imported
    /// the package lists.
    func testAFolderThatCameAfterTheManifestIsDeclaredOnce() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        await remote.makeFolder(".verbinal/research")
        await remote.put(".verbinal/manifests/images.canfar.net_skaha_astroml_24.07.json", Data("one".utf8))
        await remote.makeFolder("Verbinal-Exports")
        let imports = Imports()
        let storage = sync(remote, imports: imports)
        await storage.sync(.signedIn)
        let written = try StorageManifest.decode(try await remote.read(StorageManifest.path))
        XCTAssertEqual(Set(written.kinds.keys), ["research", "imagePackages", "exports"], "the person's kind kept")
        XCTAssertEqual(imports.count, 1, "imported in the same sync")

        let stamp = await remote.files[StorageManifest.path]?.modified
        await remote.forgetCounts()
        await storage.sync(.asked)
        let again = await remote.files[StorageManifest.path]?.modified
        XCTAssertEqual(again, stamp, "declared: not written again")
        let lists = await remote.lists
        XCTAssertFalse(lists.contains(".verbinal-scripts"), "a folder outside .verbinal is looked for once a sign-in")
    }

    func testNoFolderNoWriteAndThePersonsKindsAreNeverDeclaredThisWay() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["imagePackages": ".verbinal/manifests"]))
        await remote.makeFolder(".verbinal/manifests")
        await remote.makeFolder(".verbinal/research")
        let stamp = await remote.files[StorageManifest.path]?.modified
        await sync(remote).sync(.signedIn)
        let after = await remote.files[StorageManifest.path]?.modified
        XCTAssertEqual(after, stamp, "nothing new found: nothing written")
        let kept = try StorageManifest.decode(try await remote.read(StorageManifest.path))
        XCTAssertEqual(Set(kept.kinds.keys), ["imagePackages"], "research waits for the person")
    }

    func testUnknownKindsAndFieldsSurviveAWrite() async throws {
        let remote = FakeVOSpace()
        let original = manifest(["imagePackages": ".verbinal/manifests", "linuxNotebooks": "notebooks"],
                                extra: #""writtenBy": "Verbinal for Linux","#)
        await remote.put(StorageManifest.path, original)
        let storage = sync(remote)
        await storage.sync(.signedIn)
        try await storage.setDeclared(["research"], true)

        let text = await remote.text(StorageManifest.path) ?? ""
        let written = try StorageManifest.decode(Data(text.utf8))
        XCTAssertEqual(written.kinds["linuxNotebooks"]?.folder, "notebooks", "another app's kind is kept")
        XCTAssertTrue(text.contains("Verbinal for Linux"), "and its fields")
        XCTAssertTrue(written.declares("research"))
        XCTAssertFalse(text.contains("bookmark") || text.contains("/Users/"), "folder names and dates only")

        try await storage.setDeclared(["research"], false)
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

    // MARK: - VOSpace slow or out of service for a moment (plan 44 E3)

    /// Fails `failing` times with `error`, then answers.
    actor Flaky: StorageRemote {
        private(set) var calls = 0
        var failing: Int
        let error: Error
        init(failing: Int, error: Error) { self.failing = failing; self.error = error }
        private func attempt() throws {
            calls += 1
            if failing > 0 { failing -= 1; throw error }
        }
        func list(_ folder: String) async throws -> [StorageItem]? { try attempt(); return [] }
        func read(_ path: String) async throws -> Data { try attempt(); return Data("ok".utf8) }
        func write(_ data: Data, to path: String) async throws { try attempt() }
        func isPublic(_ folder: String) async throws -> Bool { try attempt(); return false }
        func hasHome() async throws -> Bool { try attempt(); return true }
    }

    private func retrying(_ base: Flaky) -> RetryingStorageRemote {
        RetryingStorageRemote(base: base, waits: [.zero, .zero], sleep: { _ in })
    }

    func testARequestThatTimesOutOrMeetsAServerErrorIsAskedAgain() async throws {
        let slow = Flaky(failing: 2, error: URLError(.timedOut))
        let data = try await retrying(slow).read("x")
        XCTAssertEqual(data, Data("ok".utf8))
        let calls = await slow.calls
        XCTAssertEqual(calls, 3, "twice more, then it answered")

        let busy = Flaky(failing: 1, error: NetworkError.httpError(503, "Service Unavailable"))
        try await retrying(busy).write(Data(), to: "x")
        let busyCalls = await busy.calls
        XCTAssertEqual(busyCalls, 2)
    }

    func testARefusalOrAnOutageThatLastsIsNotHiddenByRetries() async throws {
        let refused = Flaky(failing: 1, error: NetworkError.httpError(403, "Forbidden"))
        do { _ = try await retrying(refused).list("x"); XCTFail("a refusal is not asked again") } catch {}
        let refusedCalls = await refused.calls
        XCTAssertEqual(refusedCalls, 1)

        let down = Flaky(failing: 5, error: URLError(.cannotConnectToHost))
        do { _ = try await retrying(down).hasHome(); XCTFail("three tries, then it fails, saying why") } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        let downCalls = await down.calls
        XCTAssertEqual(downCalls, 3)
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

    /// Plan 45, decided 1: both changed the same note — the one in storage
    /// first stays, whatever each Mac's clock said, and this Mac's waits.
    func testBothChangedTheSameFieldStoragesStaysAndThisMacsWaits() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item(key, note: "first", at: 100))
        let syncA = sync(remote, research: a, device: "a"), syncB = sync(remote, research: b, device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        // Both change it; A's clock says its change is much the newer.
        await a.set(item(key, note: "from A", at: 4_000_000_000))
        await b.set(item(key, note: "from B", at: 300))
        await syncB.sync(.changed)
        await syncA.sync(.changed)
        let onA = await a.records[key]?.note?.text
        XCTAssertEqual(onA, "from B", "storage's, first there, stays: no clock decides")
        let waitingOnA = await waiting(syncA)
        XCTAssertEqual(waitingOnA, ["from A"], "and A's waits for the person")
        let onB = await b.records[key]?.note?.text
        XCTAssertEqual(onB, "from B")
    }

    /// Plan 44 A2: what another device writes while this one syncs is not
    /// taken for this one's own writes. The folder listed again after a send
    /// once made every file there "seen": B's change to another record never
    /// came to A.
    func testAnotherDevicesChangeDuringASyncComesAtTheNext() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        let mineKey = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
        let theirKey = "ivo://cadc.nrc.ca/CFHT?2388466/2388466p"
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item(mineKey, note: "first", at: 100))
        await a.set(item(theirKey, note: "first", at: 100))
        let syncA = sync(remote, research: a, device: "a"), syncB = sync(remote, research: b, device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)

        // A sends its change; B's, to the other record, lands as A's write does.
        await a.set(item(mineKey, note: "from A", at: 200))
        await remote.whenWritten(".verbinal/research/" + ResearchItem.fileName(for: mineKey),
                                 alsoPut: ".verbinal/research/" + ResearchItem.fileName(for: theirKey),
                                 item(theirKey, note: "from B", at: 300).encoded())
        await syncA.sync(.changed)
        await syncA.sync(.asked)
        let onA = await a.records[theirKey]?.note?.text
        XCTAssertEqual(onA, "from B", "B's change came at A's next sync")
    }

    /// Plan 44 A2: a record changed there after this device looked, before
    /// it wrote, is not written over: the newer wins, the other is kept.
    func testARecordChangedThereBeforeThisDeviceWritesIsNotWrittenOver() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
        let path = ".verbinal/research/" + ResearchItem.fileName(for: key)
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item(key, note: "first", at: 100))
        let syncA = sync(remote, research: a, device: "a"), syncB = sync(remote, research: b, device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)

        await a.set(item(key, note: "from A", at: 200))
        await remote.whenListed(".verbinal/research", alsoPut: path, item(key, note: "from B", at: 300).encoded())
        await syncA.sync(.changed)
        let onA = await a.records[key]?.note?.text
        XCTAssertEqual(onA, "from B", "the newer wins")
        let there = try ResearchItem.decode(try await remote.read(path))
        XCTAssertEqual(there.note?.text, "from B", "B's change is not written over")
        let waitingOnA = await waiting(syncA)
        XCTAssertEqual(waitingOnA, ["from A"], "and A's waits for the person")
    }

    /// Plan 44 A2: another device writing over the file this one has just
    /// written (another size) is not taken for this one's write.
    func testAFileWrittenOverRightAfterThisDeviceWroteItComesAtTheNextSync() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
        let path = ".verbinal/research/" + ResearchItem.fileName(for: key)
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item(key, note: "first", at: 100))
        let syncA = sync(remote, research: a, device: "a"), syncB = sync(remote, research: b, device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)

        await a.set(item(key, note: "from A", at: 200))
        await remote.whenWritten(path, alsoPut: path, item(key, note: "from B, a little later", at: 300).encoded())
        await syncA.sync(.changed)
        await syncA.sync(.asked)
        let onA = await a.records[key]?.note?.text
        XCTAssertEqual(onA, "from B, a little later")
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

    /// Plan 36 1.8: fields a later build wrote — at the top, and in
    /// `details` and `note` — survive this build's changes to the item.
    func testFieldsThisBuildDoesNotKnowSurviveItsChanges() async throws {
        let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
        var later = try JSONSerialization.jsonObject(with: item(key, note: "first", at: 100).encoded()) as! [String: Any]
        later["results"] = [["name": "fit.json", "origin": "run 42"]]
        var details = later["details"] as! [String: Any]
        details["status"] = "candidate"
        later["details"] = details
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["research": ".verbinal/research"]))
        await remote.put(".verbinal/research/" + ResearchItem.fileName(for: key), try JSONSerialization.data(withJSONObject: later))

        let here = FakeResearch()
        let storage = sync(remote, research: here)
        await storage.sync(.signedIn)
        await here.set(item(key, note: "edited here", at: 500))
        await storage.sync(.changed)

        let sent = try JSONSerialization.jsonObject(with: try await remote.read(".verbinal/research/" + ResearchItem.fileName(for: key))) as! [String: Any]
        XCTAssertEqual((sent["note"] as? [String: Any])?["text"] as? String, "edited here", "this build's change went")
        XCTAssertNotNil(sent["results"], "a later build's field stayed")
        XCTAssertEqual((sent["details"] as? [String: Any])?["status"] as? String, "candidate", "and a nested one")
        XCTAssertNil(sent["removedAt"])
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
        XCTAssertEqual(note, CollectionSync.publicNote)
    }

    // MARK: - How far it has got, and pausing (plan 40)

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [StorageSync.Event] = []
        func add(_ event: StorageSync.Event) { lock.withLock { list.append(event) } }
        var all: [StorageSync.Event] { lock.withLock { list } }
    }

    /// The sync, for an import that pauses it halfway.
    private final class Holder: @unchecked Sendable { var storage: StorageSync? }

    private func lists(_ remote: FakeVOSpace, count: Int) async {
        await remote.put(StorageManifest.path, manifest(["imagePackages": ".verbinal/manifests"]))
        for index in 1...count {
            await remote.put(".verbinal/manifests/image-\(index).json", Data("list \(index)".utf8))
        }
    }

    func testASyncSaysHowFarEachKindHasGotAndWhatMoved() async throws {
        let remote = FakeVOSpace()
        await lists(remote, count: 10)
        let events = Events()
        await sync(remote, watcher: { events.add($0) }).sync(.signedIn)
        let counts = events.all.compactMap { event -> Int? in
            if case .progress(let count) = event, count.kind == "imagePackages" { return count.done } else { return nil }
        }
        XCTAssertEqual(counts, Array(0...10))
        XCTAssertEqual(events.all.last, .ended(imported: 10, sent: 0, failure: nil, paused: false))
    }

    func testAPauseKeepsWhatWasTakenAndResumingGoesOnFromTheNext() async throws {
        let remote = FakeVOSpace()
        await lists(remote, count: 10)
        let imports = Imports(), events = Events(), holder = Holder()
        let storage = sync(remote, importing: { data in
            imports.add(data)
            if imports.count == 3 { await holder.storage?.pause(by: .assistant, why: "the person is on a slow network") }
            return true
        }, watcher: { events.add($0) })
        holder.storage = storage
        await storage.sync(.signedIn)
        XCTAssertEqual(imports.count, 3, "the item under way finishes; nothing after it")
        XCTAssertEqual(events.all.last, .ended(imported: 0, sent: 0, failure: nil, paused: true))
        let paused = await storage.status().paused
        XCTAssertEqual(paused?.by, "assistant")
        XCTAssertEqual(paused?.why, "the person is on a slow network")
        XCTAssertEqual(paused?.kind, "imagePackages")
        XCTAssertEqual(paused?.done, 3)
        XCTAssertEqual(paused?.total, 10)

        for reason in [StorageSync.Reason.cameBack, .changed, .asked] { await storage.sync(reason) }
        XCTAssertEqual(imports.count, 3, "nothing runs while paused, asked or not")

        // A relaunch: the same state, another sync. Still paused, and the
        // three taken are kept.
        let again = Imports()
        let relaunched = sync(remote, imports: again)
        let kept = await relaunched.status()
        XCTAssertNotNil(kept.paused, "a relaunch does not resume it")
        XCTAssertEqual(kept.kinds.first { $0.id == "imagePackages" }?.items, 3, "each list kept as it was taken")
        await relaunched.sync(.signedIn)
        XCTAssertEqual(again.count, 0)
        await relaunched.resume()
        await relaunched.sync(.asked)
        XCTAssertEqual(again.count, 7, "it goes on from the next list, not from the first")
        let done = await relaunched.status()
        XCTAssertNil(done.paused)
        XCTAssertEqual(done.kinds.first { $0.id == "imagePackages" }?.items, 10)
    }

    /// A relaunch takes nothing as changed that was not (2026-10-16): VOSpace
    /// dates carry milliseconds, the state file kept whole seconds, and after
    /// every relaunch each item looked changed — the person's 288 package
    /// lists and 474 runs fetched again at each launch, while a second sync
    /// in the same run moved nothing.
    func testARelaunchFetchesNothingThatDidNotChange() async throws {
        let remote = FakeVOSpace()
        await remote.useFractionalTimes()
        await lists(remote, count: 5)
        let imports = Imports()
        await sync(remote, imports: imports).sync(.signedIn)
        XCTAssertEqual(imports.count, 5)

        let afterRelaunch = Imports()
        await remote.forgetCounts()
        await sync(remote, imports: afterRelaunch).sync(.signedIn)
        XCTAssertEqual(afterRelaunch.count, 0, "nothing changed: nothing fetched again")
        let reads = await remote.reads
        XCTAssertEqual(reads, [], "not even the manifest is read again")

        await remote.put(".verbinal/manifests/image-3.json", Data("changed".utf8))
        await sync(remote, imports: afterRelaunch).sync(.signedIn)
        XCTAssertEqual(afterRelaunch.count, 1, "a list that changed still comes")
    }

    @MainActor
    func testTheBarShowsASyncThatMovesFiveOrMoreAndTheImageToolsAreTold() {
        let registry = TaskRegistry()
        let model = StorageSyncModel(tasks: registry)
        model.heard(.progress(.init(kind: "savedQueries", done: 0, total: 1)))
        model.heard(.ended(imported: 1, sent: 0, failure: nil, paused: false))
        XCTAssertTrue(registry.tasks.isEmpty, "one saved query is not a line on the bar")

        model.heard(.progress(.init(kind: "imagePackages", done: 0, total: 288)))
        model.heard(.progress(.init(kind: "imagePackages", done: 120, total: 288)))
        let task = try? XCTUnwrap(registry.tasks.first)
        XCTAssertEqual(task?.label, "Syncing with your storage")
        XCTAssertEqual(task?.startedBy, .app)
        XCTAssertEqual(task?.stage, "Image package lists")
        XCTAssertEqual(task?.canPause, true)
        XCTAssertEqual(model.taskID, task?.id)
        XCTAssertEqual(model.packageListsNote,
                       "Package lists are still coming from the person's storage: 120 of 288 so far. Results may be incomplete.")
        model.heard(.ended(imported: 288, sent: 0, failure: nil, paused: false))
        XCTAssertEqual(registry.tasks.first?.progress, .succeeded)
        XCTAssertEqual(registry.tasks.first?.message, "288 brought to this Mac")
        XCTAssertNil(model.packageListsNote)
        XCTAssertNil(model.taskID)

        // A stopped sync's last words — its run ending after a sign-out —
        // are not the next one's.
        model.heard(.progress(.init(kind: "imagePackages", done: 0, total: 10)))
        model.signedOut()
        model.heard(.ended(imported: 10, sent: 0, failure: nil, paused: false), from: -1)
        XCTAssertEqual(registry.tasks.last?.progress, .cancelled, "signed out: abandoned, not succeeded by the old sync")
    }

    func testTheImageToolsSayWhenListsAreStillComing() async throws {
        struct Answers: AITool {
            static var verbClass: VerbClass { .read }
            static var agentSafe: Bool { true }
            let definition = AIToolDefinition.withStaticSchema(name: "fake_images", description: "x",
                                                               schema: #"{ "type": "object", "properties": {} }"#)
            let fails: Bool
            func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
                fails ? .failed(.unknownTarget("'x' has not been probed")) : .data(Data(#"{"count":0}"#.utf8))
            }
        }
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        let words = "Package lists are still coming from the person's storage: 3 of 10 so far. Results may be incomplete."
        guard case .data(let data) = await ArrivingNoteTool(wrapped: Answers(fails: false), note: { words })
            .invoke(arguments: Data("{}".utf8), context: ctx) else { return XCTFail() }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["arriving"] as? String, words)
        XCTAssertEqual(object["count"] as? Int, 0)
        guard case .failed(.unknownTarget(let why)) = await ArrivingNoteTool(wrapped: Answers(fails: true), note: { words })
            .invoke(arguments: Data("{}".utf8), context: ctx) else { return XCTFail() }
        XCTAssertEqual(why, "'x' has not been probed. " + words)
        guard case .data(let plain) = await ArrivingNoteTool(wrapped: Answers(fails: false), note: { nil })
            .invoke(arguments: Data("{}".utf8), context: ctx) else { return XCTFail() }
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), #"{"count":0}"#, "nothing coming: the answer as it was")
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

    /// Live, plan 44 F-9: storage was pointed at a dead address, failed five
    /// times, and was set back with a relaunch. The relaunch's sign-in sync
    /// waited out the failures — 16 minutes, unseen — and a result made
    /// meanwhile waited with it. A sign-in syncs whatever failed before.
    func testASignInSyncsThoughSyncsFailedBefore() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["exports": "Verbinal-Exports"]))
        await remote.setFailing(true)
        await sync(remote).sync(.signedIn)
        await remote.setFailing(false)
        await remote.forgetCounts()
        // Relaunched: a new sync, the same state on this Mac.
        let relaunched = sync(remote)
        await relaunched.sync(.signedIn)
        let lists = await remote.lists
        XCTAssertFalse(lists.isEmpty, "the sign-in sync ran")
        let status = await relaunched.status()
        XCTAssertNil(status.lastFailure)
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
        let work = AppState().workCollections(username: "someone")
        XCTAssertEqual(work.map(\.kind.id), StorageKindCatalog.work, "every collection, in the order the person reads them")
        let catalog = StorageSyncModel.catalog(.init(
            vospace: VOSpaceBrowserService(network: NetworkClient()), work: work,
            importManifest: { _ in false }, resumeRuns: {}))
        XCTAssertEqual(catalog.kinds.map(\.id).sorted(), StorageKindCatalog.order.sorted())
        for id in StorageKindCatalog.order {
            XCTAssertNotEqual(StorageSettingsTab.title(id), id, "\(id) has a title")
        }
    }
}
