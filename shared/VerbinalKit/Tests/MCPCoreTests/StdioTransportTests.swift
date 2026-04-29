// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

/// Pipe-backed transport tests. We can't drive `FileHandle.standardInput`
/// directly, so we hand `StdioTransport` the read/write ends of a Pipe and
/// drive both sides in-process.
final class StdioTransportTests: XCTestCase {

    func testRoundTripsSingleMessage() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let transport = StdioTransport(
            stdin: inputPipe.fileHandleForReading,
            stdout: outputPipe.fileHandleForWriting
        )

        // Send a payload — the framed bytes should appear on outputPipe.
        let payload = Data("{\"hello\":\"world\"}".utf8)
        try await transport.send(payload)

        let written = outputPipe.fileHandleForReading.availableData
        XCTAssertEqual(written, FrameCodec.encode(payload, mode: .ndjson))

        // Feed a framed message into stdin — receive it on `incoming`.
        let inboundPayload = Data("{\"in\":1}".utf8)
        let inboundFrame = FrameCodec.encode(inboundPayload, mode: .ndjson)
        try inputPipe.fileHandleForWriting.write(contentsOf: inboundFrame)

        var iterator = transport.incoming.makeAsyncIterator()
        let received = try await iterator.next()
        XCTAssertEqual(received, inboundPayload)

        await transport.close()
    }

    func testStreamFinishesOnEOF() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let transport = StdioTransport(
            stdin: inputPipe.fileHandleForReading,
            stdout: outputPipe.fileHandleForWriting
        )

        // Close the writing end → the reading end will see EOF on next read.
        try inputPipe.fileHandleForWriting.close()

        var iterator = transport.incoming.makeAsyncIterator()
        let result = try await iterator.next()
        XCTAssertNil(result, "incoming stream should finish on EOF")

        await transport.close()
    }

    func testSendAfterCloseThrows() async throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let transport = StdioTransport(
            stdin: inputPipe.fileHandleForReading,
            stdout: outputPipe.fileHandleForWriting
        )
        await transport.close()
        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("expected throw after close")
        } catch let err as MCPTransportError {
            XCTAssertEqual(err, .closed)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
