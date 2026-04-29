// SPDX-License-Identifier: MPL-2.0

import XCTest
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
            throw MCPTransportError.peerClosed
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
}
