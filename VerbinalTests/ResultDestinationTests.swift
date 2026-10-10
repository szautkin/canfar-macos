// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 36 4.1, as the person decided (2026-10-09): results go to the Mac
/// first; to their CANFAR storage too only when they keep results there,
/// sent in the background and kept to send while storage cannot be reached.
@MainActor
final class ResultDestinationTests: XCTestCase {

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(String, String)] = []
        var failing = false
        @discardableResult
        func add(_ file: URL, _ folder: String) throws -> String {
            try lock.withLock {
                if failing { throw URLError(.notConnectedToInternet) }
                list.append((file.lastPathComponent, folder))
            }
            return "\(folder)/\(file.lastPathComponent)"
        }
        var all: [String] { lock.withLock { list.map { "\($0.1)/\($0.0)" } } }
    }

    private func result(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("result-\(UUID().uuidString)-\(name)")
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    func testAResultStaysOnTheMacUnlessThePersonKeepsResultsInStorage() async {
        let destination = ResultDestination(persistence: nil)
        let sent = Sent()
        destination.send = { file, folder in try sent.add(file, folder) }
        destination.kept(result("fig.png"), area: .figures)
        XCTAssertTrue(destination.waiting.isEmpty, "not chosen: the Mac only")

        destination.keeping = true
        let figure = result("fig.png")
        destination.kept(figure, area: .figures)
        destination.kept(figure, area: .figures)
        XCTAssertEqual(destination.waiting.count, 1, "once")
        let count = await destination.sendWaiting()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(sent.all, ["Verbinal-Results/figures/\(figure.lastPathComponent)"])
        XCTAssertTrue(destination.waiting.isEmpty)
    }

    func testWhatCannotGoWaitsForTheNextSync() async {
        let destination = ResultDestination(persistence: nil)
        let sent = Sent()
        sent.failing = true
        destination.send = { file, folder in try sent.add(file, folder) }
        destination.keeping = true
        destination.kept(result("a.csv"), area: .searches)
        destination.kept(URL(fileURLWithPath: "/nowhere/gone.fits"), area: .research)
        let none = await destination.sendWaiting()
        XCTAssertEqual(none, 0)
        XCTAssertEqual(destination.waiting.count, 2, "offline: both wait")
        sent.failing = false
        let later = await destination.sendWaiting()
        XCTAssertEqual(later, 1)
        XCTAssertTrue(destination.waiting.isEmpty, "the one no longer on the Mac is let go")
    }

    func testTheSyncSendsThemWhenTheManifestDeclaresResults() async throws {
        let remote = StorageSyncTests.FakeVOSpace()
        await remote.put(StorageManifest.path, Data(#"{ "format": "verbinal.vospace-manifest", "version": 1, "kinds": { "results": { "folder": "Verbinal-Results", "format": 1, "since": "2026-10-09T12:00:00Z" } } }"#.utf8))
        let calls = Sent()
        let kind = ResultsKind(send: { try? calls.add(URL(fileURLWithPath: "/x"), "sync"); return 1 })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("results-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageSync(remote: remote, catalog: StorageKindCatalog(kinds: [kind]),
                                  stateFile: directory.appendingPathComponent("state.json"))
        await storage.sync(.signedIn)
        XCTAssertEqual(calls.all.count, 1)
        let sentCount = await storage.status().kinds.first?.sent
        XCTAssertEqual(sentCount, 1)
    }
}
