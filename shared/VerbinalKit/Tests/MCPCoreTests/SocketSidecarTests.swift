// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

final class SocketSidecarTests: XCTestCase {

    /// Every write goes to a temp directory: the default is the real App
    /// Group container, where a test would overwrite — and `clear()` would
    /// delete — the sidecar of a Verbinal running on this Mac.
    private var sidecarDir: URL!

    override func setUpWithError() throws {
        sidecarDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canfar-mac-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sidecarDir)
    }

    func testCandidateDirectoriesIncludeLegacyPaths() {
        // The legacy paths (Library/Containers/<bundle>/...,
        // Library/Application Support/<bundle>) are always present as
        // read fallbacks. The App Group container is prepended *only*
        // when the calling process holds the entitlement — in unit
        // tests run via `swift test` it doesn't, so we don't assert
        // on the group container here.
        let dirs = SocketSidecar.candidateDirectories()
        let paths = dirs.map(\.path)
        XCTAssertTrue(paths.contains { $0.contains("Library/Containers") && $0.contains(SocketSidecar.appBundleID) })
        XCTAssertTrue(paths.contains { $0.contains("Library/Application Support") && $0.contains(SocketSidecar.appBundleID) })
    }

    func testWriteThenReadRoundTrip() throws {
        let socketPath = "/tmp/canfar-mac-mcp-test-\(UUID().uuidString).sock"

        let written = try SocketSidecar.write(socketPath: socketPath, directory: sidecarDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(try SocketSidecar.read(directories: [sidecarDir]), socketPath)

        SocketSidecar.clear(directory: sidecarDir)
        XCTAssertThrowsError(try SocketSidecar.read(directories: [sidecarDir]))
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

        let url = try SocketSidecar.write(socketPath: socketPath, directory: sidecarDir)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk, Data((socketPath + "\n").utf8))
    }

    func testSuggestedSocketPathIncludesPID() {
        let path = SocketSidecar.suggestedSocketPath()
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(path.contains("mcp-\(pid)"))
        XCTAssertTrue(path.hasSuffix(".sock"))
    }

    // MARK: - Plan 36 2.2–2.4: a sidecar no one else's run can spoil

    /// A short socket path in the temporary directory (sun_path is 104 bytes).
    private func socketPath(_ name: String) -> String {
        "/tmp/vb-\(name)-\(UUID().uuidString.prefix(8)).sock"
    }

    func testClearingRemovesOnlyTheSidecarThatNamesThisSocket() throws {
        try SocketSidecar.write(socketPath: "/tmp/theirs.sock", directory: sidecarDir)
        SocketSidecar.clear(ifNaming: "/tmp/mine.sock", directory: sidecarDir)
        XCTAssertEqual(try SocketSidecar.read(directories: [sidecarDir]), "/tmp/theirs.sock", "another's sidecar stays")
        SocketSidecar.clear(ifNaming: "/tmp/theirs.sock", directory: sidecarDir)
        XCTAssertThrowsError(try SocketSidecar.read(directories: [sidecarDir]), "its own goes")
    }

    func testSocketsAreListedNewestFirst() throws {
        let fm = FileManager.default
        for (name, age) in [("mcp-1.sock", 300.0), ("mcp-2.sock", 10.0), ("mcp-3.sock", 100.0), ("other.txt", 0.0)] {
            let url = sidecarDir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data())
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        XCTAssertEqual(SocketSidecar.socketsNewestFirst(in: sidecarDir).map { ($0 as NSString).lastPathComponent },
                       ["mcp-2.sock", "mcp-3.sock", "mcp-1.sock"])
    }

    func testASocketIsListeningOnlyWhileAServerHoldsIt() throws {
        let path = socketPath("listen")
        let server = SocketServer(socketPath: path)
        try server.start()
        XCTAssertTrue(SocketSidecar.isListening(path))
        server.stop()
        XCTAssertFalse(SocketSidecar.isListening(path))
        XCTAssertFalse(SocketSidecar.isListening(socketPath("never")))
    }
}
