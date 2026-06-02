// SPDX-License-Identifier: MPL-2.0

import XCTest
import Darwin
@testable import MCPCore

/// End-to-end test: stand up a `SocketServer`, connect with a client
/// `SocketTransport`, exchange a frame each way. Pins the framing+
/// connection pipeline that the helper relies on.
final class SocketTransportTests: XCTestCase {

    func testClientServerRoundTrip() async throws {
        let socketPath = NSTemporaryDirectory() + "mcpcore-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let server = SocketServer(socketPath: socketPath)
        try server.start()

        // Take the first accepted server-side transport off the stream.
        let acceptedTask = Task { () -> SocketTransport in
            for await transport in server.connections {
                return transport
            }
            // Connections stream finished before any client connected —
            // surface as a transport-closed sentinel so `acceptedTask.value`
            // throws and the test fails loudly.
            throw MCPTransportError.closed
        }

        let client = SocketTransport.client(socketPath: socketPath)
        try await client.start()

        let serverSide = try await acceptedTask.value

        // Client → server
        let outbound = Data("{\"hello\":\"server\"}".utf8)
        try await client.send(outbound)
        var serverIter = serverSide.incoming.makeAsyncIterator()
        let receivedAtServer = try await serverIter.next()
        XCTAssertEqual(receivedAtServer, outbound)

        // Server → client
        let inbound = Data("{\"reply\":\"client\"}".utf8)
        try await serverSide.send(inbound)
        var clientIter = client.incoming.makeAsyncIterator()
        let receivedAtClient = try await clientIter.next()
        XCTAssertEqual(receivedAtClient, inbound)

        await client.close()
        await serverSide.close()
        server.stop()
    }

    // Missing-socket failure mode: not unit-tested here because Network.framework
    // raises a debug-only assertion when an `NWConnection` to a non-existent
    // unix path is started. The helper's `drainAndFail` path covers the
    // user-visible behaviour through integration tests instead.

    // MARK: - Clean-close contract (EOF finishes the stream WITHOUT throwing)

    /// When the peer closes the connection (read returns 0 / EOF), the
    /// `incoming` stream must finish cleanly — never surface an error.
    /// This is the contract that justifies removing `MCPTransportError.peerClosed`.
    func testSocketTransportEOFFinishesStreamCleanly() async throws {
        // A connected socket pair: index 0 is the local end the transport
        // reads from, index 1 is the peer we close to trigger EOF.
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { ptr in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, ptr.baseAddress)
        }
        XCTAssertEqual(rc, 0, "socketpair() failed: \(posixMessage())")
        let localFD = fds[0]
        let peerFD = fds[1]

        let transport = SocketTransport(connectedFD: localFD)
        try await transport.start()

        // Drain the stream on a child task; closing the peer must let it
        // finish WITHOUT throwing.
        let drain = Task { () -> Bool in
            for try await _ in transport.incoming {
                // No frames expected; any element would be unexpected but
                // still wouldn't be an error.
            }
            return true // finished cleanly
        }

        // Close the peer end → the transport's read(2) returns 0 (EOF).
        _ = Darwin.close(peerFD)

        let finishedCleanly = try await drain.value
        XCTAssertTrue(finishedCleanly, "EOF should finish the stream cleanly, not throw")

        await transport.close()
    }

    /// Same clean-close contract for `StdioTransport`: closing the write
    /// end of the inbound pipe (EOF) finishes `incoming` without throwing.
    func testStdioTransportEOFFinishesStreamCleanly() async throws {
        let inboundPipe = Pipe()   // we write to .fileHandleForWriting; transport reads .forReading
        let outboundPipe = Pipe()  // transport's stdout; unused here

        let transport = StdioTransport(
            stdin: inboundPipe.fileHandleForReading,
            stdout: outboundPipe.fileHandleForWriting
        )

        let drain = Task { () -> Bool in
            for try await _ in transport.incoming {
                // No frames expected.
            }
            return true // finished cleanly
        }

        // Close the writer end → read(2) on stdin returns 0 (EOF).
        try inboundPipe.fileHandleForWriting.close()

        let finishedCleanly = try await drain.value
        XCTAssertTrue(finishedCleanly, "EOF should finish the stream cleanly, not throw")

        await transport.close()
    }
}
