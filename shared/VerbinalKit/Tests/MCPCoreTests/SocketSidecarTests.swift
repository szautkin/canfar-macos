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
        // Don't write into the user's real Application Support during tests —
        // skip the round-trip if running under CI without that location, but
        // do exercise the path machinery.
        let socketPath = "/tmp/canfar-mac-mcp-test-\(UUID().uuidString).sock"
        defer { SocketSidecar.clear() }

        let written = try SocketSidecar.write(socketPath: socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))

        let read = try SocketSidecar.read()
        XCTAssertEqual(read, socketPath)
    }

    func testReadWithoutSidecarThrows() throws {
        SocketSidecar.clear()
        XCTAssertThrowsError(try SocketSidecar.read()) { err in
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
