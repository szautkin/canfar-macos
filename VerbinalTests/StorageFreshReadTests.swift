// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 44 F, live (2026-10-17): the sync wrote one changed saved query
/// three times at every sync. Each read after the write was a copy from the
/// URL cache, so the read-back never saw the write, took it for overtaken,
/// and wrote again. Storage is read as it is now; and a write storage does
/// not show yet is not written again in the same sync.
final class StorageFreshReadTests: XCTestCase {
    typealias FakeVOSpace = StorageSyncTests.FakeVOSpace
    typealias FakeResearch = StorageSyncTests.FakeResearch

    /// Storage that shows a file as it was before its last write, until it
    /// catches up — as the cached copies did.
    actor Lagging: StorageRemote {
        let base: FakeVOSpace
        private var before: [String: Data?] = [:]
        private(set) var writes = 0
        var lagging = true

        init(_ base: FakeVOSpace) { self.base = base }

        func catchUp() { before = [:] }
        func setLagging(_ value: Bool) { lagging = value }

        func list(_ folder: String) async throws -> [StorageItem]? { try await base.list(folder) }
        func read(_ path: String) async throws -> Data {
            if let shown = before[path] {
                guard let shown else { throw URLError(.fileDoesNotExist) }
                return shown
            }
            return try await base.read(path)
        }
        func write(_ data: Data, to path: String) async throws {
            if lagging, before[path] == nil { before[path] = .some(try? await base.read(path)) }
            writes += 1
            try await base.write(data, to: path)
        }
        func isPublic(_ folder: String) async throws -> Bool { try await base.isPublic(folder) }
        func hasHome() async throws -> Bool { try await base.hasHome() }
    }

    private var directory: URL!
    private let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
    private var path: String { ".verbinal/research/" + ResearchItem.fileName(for: key) }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func item(note: String) -> ResearchItem {
        ResearchItem(recordKey: key, changedAt: Date(timeIntervalSince1970: 100),
                     details: .init(publisherID: key, collection: "CFHT", observationID: "1525350", targetName: "M31",
                                    instrument: "MegaPrime", filter: "r", ra: "", dec: "", startDate: "", calLevel: "2"),
                     note: .init(text: note, rating: 3, tags: ["usable"]))
    }

    func testAWriteStorageDoesNotShowYetIsNotWrittenAgain() async throws {
        let fake = FakeVOSpace()
        let manifest = #"{ "format": "verbinal.vospace-manifest", "version": 1, "kinds": { "research": { "folder": ".verbinal/research", "format": 1, "since": "2026-10-17T12:00:00Z" } } }"#
        await fake.put(StorageManifest.path, Data(manifest.utf8))
        let remote = Lagging(fake)
        let research = FakeResearch()
        await research.set(item(note: "first"))
        let sync = StorageSync(remote: remote, catalog: StorageKindCatalog(kinds: [
            CollectionKind(id: "research", defaultFolder: ".verbinal/research", collection: research),
        ]), stateFile: directory.appendingPathComponent("state.json"))

        await sync.sync(.signedIn)
        var writes = await remote.writes
        XCTAssertEqual(writes, 1, "a new record is written once, though storage does not show it yet")

        await remote.catchUp()
        await sync.sync(.asked)
        writes = await remote.writes
        XCTAssertEqual(writes, 1, "seen standing at the next sync: not written again")

        await research.set(item(note: "second"))
        await sync.sync(.changed)
        writes = await remote.writes
        XCTAssertEqual(writes, 2, "a change is written once")
        await remote.catchUp()
        await sync.sync(.asked)
        writes = await remote.writes
        XCTAssertEqual(writes, 2)
        let stored = SyncRevision(of: try ResearchItem.decode(try await fake.read(path)))
        XCTAssertEqual(stored.rev, 2, "made from revision 1: its base settled when it was seen")
        XCTAssertEqual(stored.base, 1)
    }

    /// Storage's listings, nodes and files are never answered from the URL cache.
    func testStorageIsReadAsItIsNow() async throws {
        let policies = Policies()
        MockURLProtocol.requestHandler = { request in
            policies.add(request.cachePolicy)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let service = VOSpaceBrowserService(network: NetworkClient(session: MockURLProtocol.mockSession()))
        _ = try? await service.listNodes(username: "qa", path: ".verbinal/queries")
        _ = try? await service.node(username: "qa", path: ".verbinal")
        _ = try? await service.downloadFile(username: "qa", path: ".verbinal/queries/a.json")
        _ = try? await service.fetchBytes(username: "qa", path: ".verbinal/queries/a.json", offset: 0, maxBytes: 10)
        let seen = policies.all
        XCTAssertEqual(seen.count, 4, "one request each")
        XCTAssertEqual(seen.filter { $0 != .reloadIgnoringLocalCacheData }, [], "every read skips the local cache")
    }

    private final class Policies: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URLRequest.CachePolicy] = []
        func add(_ policy: URLRequest.CachePolicy) { lock.withLock { list.append(policy) } }
        var all: [URLRequest.CachePolicy] { lock.withLock { list } }
    }
}
