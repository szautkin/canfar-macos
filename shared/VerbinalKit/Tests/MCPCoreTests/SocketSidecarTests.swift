// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

final class SocketSidecarTests: XCTestCase {

    func testCandidateDirectoriesIncludeSandboxedAndUnsandboxed() {
        let dirs = SocketSidecar.candidateDirectories()
        XCTAssertEqual(dirs.count, 2)
        XCTAssertTrue(dirs[0].path.contains("Library/Containers"))
        XCTAssertTrue(dirs[0].path.contains(SocketSidecar.appBundleID))
        XCTAssertTrue(dirs[1].path.contains("Library/Application Support"))
        XCTAssertTrue(dirs[1].path.contains(SocketSidecar.appBundleID))
    }

    func testWriteThenReadRoundTrip() throws {
        // Scope the read to a temp dir so a real running app's sidecar
        // (which lives in ~/Library/Containers/<bundle>/...) can't shadow
        // the test's own writes during local development.
        let socketPath = "/tmp/canfar-mac-mcp-test-\(UUID().uuidString).sock"
        defer { SocketSidecar.clear() }

        let written = try SocketSidecar.write(socketPath: socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))

        let parentDir = written.deletingLastPathComponent()
        let read = try SocketSidecar.read(directories: [parentDir])
        XCTAssertEqual(read, socketPath)
    }

    func testReadWithoutSidecarThrows() throws {
        // Use an isolated temp dir that's guaranteed to be empty so the
        // production app (if running) doesn't pollute the result.
        let isolatedDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canfar-mac-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedDir) }
        XCTAssertThrowsError(try SocketSidecar.read(directories: [isolatedDir])) { err in
            XCTAssertEqual(err as? SocketSidecar.Error, .sidecarMissing)
        }
    }

    func testWriteIsAtomic() throws {
        // Atomic writes guarantee that a reader never sees a half-written
        // file. We can't easily race the writer in a unit test, but we can
        // pin that the resulting file is exactly the bytes we asked for.
        let socketPath = "/tmp/canfar-mac-mcp-test-atomic.sock"
        defer { SocketSidecar.clear() }

        let url = try SocketSidecar.write(socketPath: socketPath)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, Data((socketPath + "\n").utf8))
    }

    func testSuggestedSocketPathIncludesPID() {
        let path = SocketSidecar.suggestedSocketPath()
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(path.contains("mcp-\(pid)"))
        XCTAssertTrue(path.hasSuffix(".sock"))
    }
}
