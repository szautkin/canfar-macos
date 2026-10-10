// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
@testable import Verbinal

/// Plan 36 2.2–2.3: the app keeps the sidecar naming its own server — after
/// a test host or a crashed run wrote another — and removes only its own.
@MainActor
final class SidecarKeeperTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vb-keeper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sidecar() -> String? { try? SocketSidecar.read(directories: [directory]) }
    private func path(_ name: String) -> String { "/tmp/vb-\(name)-\(UUID().uuidString.prefix(8)).sock" }

    func testItRewritesASidecarThatNamesASocketNobodyListensAt() throws {
        let mine = path("mine")
        let keeper = SidecarKeeper(directory: directory, interval: .seconds(3600))
        try keeper.serving(at: mine)
        XCTAssertEqual(sidecar(), mine)

        // A test host, then gone.
        try SocketSidecar.write(socketPath: path("dead"), directory: directory)
        XCTAssertTrue(keeper.check())
        XCTAssertEqual(sidecar(), mine)
        keeper.stopped()
    }

    func testItLeavesTheSidecarOfAnotherVerbinalThatListens() throws {
        let theirs = path("theirs")
        let server = SocketServer(socketPath: theirs)
        try server.start()
        defer { server.stop() }
        let keeper = SidecarKeeper(directory: directory, interval: .seconds(3600))
        try keeper.serving(at: path("mine"))
        try SocketSidecar.write(socketPath: theirs, directory: directory)
        XCTAssertFalse(keeper.check())
        XCTAssertEqual(sidecar(), theirs)

        keeper.stopped()
        XCTAssertEqual(sidecar(), theirs, "stopping removes only its own")
    }

    func testStoppingRemovesItsOwnSidecar() throws {
        let keeper = SidecarKeeper(directory: directory, interval: .seconds(3600))
        try keeper.serving(at: path("mine"))
        keeper.stopped()
        XCTAssertNil(sidecar())
    }
}
