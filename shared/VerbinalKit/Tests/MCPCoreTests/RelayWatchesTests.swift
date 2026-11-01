// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

/// Plan 52 A1, A2: what ends a relay with its client, and what wakes it
/// when Verbinal comes back.
final class RelayWatchesTests: XCTestCase {

    #if os(macOS)
    // A child process to watch: iOS has no Process, and no relay runs there.
    func testAProcessExitingIsTold() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.2"]
        try child.run()
        let exited = expectation(description: "exited")
        let watch = ProcessExitWatch(pid: child.processIdentifier) { exited.fulfill() }
        wait(for: [exited], timeout: 3)
        withExtendedLifetime(watch) {}
    }
    #endif

    func testAFileWrittenInTheFolderIsTold() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vb-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let changed = expectation(description: "changed")
        changed.assertForOverFulfill = false
        let watch = try XCTUnwrap(FolderWatch(directory: folder) { changed.fulfill() })
        try Data("/tmp/mcp-1.sock\n".utf8).write(to: folder.appendingPathComponent("mcp.sock-path"), options: .atomic)
        wait(for: [changed], timeout: 3)
        withExtendedLifetime(watch) {}
    }

    func testAFolderThatIsNotThereIsNotWatched() {
        XCTAssertNil(FolderWatch(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")) {})
    }
}
