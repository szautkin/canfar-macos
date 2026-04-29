// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

final class FrameCodecTests: XCTestCase {

    // MARK: - Encoding

    func testNDJSONEncodeAppendsSingleNewline() {
        let payload = Data("{\"x\":1}".utf8)
        let framed = FrameCodec.encode(payload, mode: .ndjson)
        XCTAssertEqual(framed, Data("{\"x\":1}\n".utf8))
    }

    func testContentLengthEncodeWritesHeaderAndBody() {
        let payload = Data("{\"x\":1}".utf8)
        let framed = FrameCodec.encode(payload, mode: .contentLength)
        XCTAssertEqual(framed, Data("Content-Length: 7\r\n\r\n{\"x\":1}".utf8))
    }

    func testEncodeEmptyPayload() {
        XCTAssertEqual(FrameCodec.encode(Data(), mode: .ndjson), Data([0x0A]))
        XCTAssertEqual(FrameCodec.encode(Data(), mode: .contentLength),
                       Data("Content-Length: 0\r\n\r\n".utf8))
    }

    // MARK: - NDJSON decode

    func testNDJSONDecodesSingleFrame() throws {
        let dec = FrameCodec.Decoder(mode: .ndjson)
        let frames = try dec.feed(Data("{\"a\":1}\n".utf8))
        XCTAssertEqual(frames, [Data("{\"a\":1}".utf8)])
    }

    func testNDJSONDecodesMultipleFramesInOneFeed() throws {
        let dec = FrameCodec.Decoder(mode: .ndjson)
        let frames = try dec.feed(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(frames, [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
    }

    func testNDJSONHandlesPartialThenComplete() throws {
        let dec = FrameCodec.Decoder(mode: .ndjson)
        XCTAssertEqual(try dec.feed(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(try dec.feed(Data("1}\n".utf8)), [Data("{\"a\":1}".utf8)])
    }

    func testNDJSONToleratesCRLFLineEndings() throws {
        let dec = FrameCodec.Decoder(mode: .ndjson)
        let frames = try dec.feed(Data("{\"a\":1}\r\n".utf8))
        XCTAssertEqual(frames, [Data("{\"a\":1}".utf8)])
    }

    func testNDJSONSkipsBlankLines() throws {
        let dec = FrameCodec.Decoder(mode: .ndjson)
        let frames = try dec.feed(Data("\n\n{\"a\":1}\n".utf8))
        // Blank lines decode as empty payloads — bridge layer ignores them.
        XCTAssertEqual(frames, [Data(), Data(), Data("{\"a\":1}".utf8)])
    }

    // MARK: - Content-Length decode

    func testContentLengthDecodesSingleFrame() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        let frame = "Content-Length: 7\r\n\r\n{\"a\":1}"
        let frames = try dec.feed(Data(frame.utf8))
        XCTAssertEqual(frames, [Data("{\"a\":1}".utf8)])
    }

    func testContentLengthHandlesPartialHeader() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        XCTAssertEqual(try dec.feed(Data("Content-Length: ".utf8)), [])
        XCTAssertEqual(try dec.feed(Data("7\r\n\r\n".utf8)), [])
        XCTAssertEqual(try dec.feed(Data("{\"a\":1}".utf8)),
                       [Data("{\"a\":1}".utf8)])
    }

    func testContentLengthHandlesPartialBody() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        XCTAssertEqual(try dec.feed(Data("Content-Length: 7\r\n\r\n{\"a\"".utf8)), [])
        XCTAssertEqual(try dec.feed(Data(":1}".utf8)),
                       [Data("{\"a\":1}".utf8)])
    }

    func testContentLengthDecodesMultipleFramesInOneFeed() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        let payload = "Content-Length: 7\r\n\r\n{\"a\":1}Content-Length: 7\r\n\r\n{\"b\":2}"
        XCTAssertEqual(try dec.feed(Data(payload.utf8)),
                       [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
    }

    func testContentLengthIgnoresExtraHeaders() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        let frame = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        XCTAssertEqual(try dec.feed(Data(frame.utf8)),
                       [Data("{\"a\":1}".utf8)])
    }

    func testContentLengthIsCaseInsensitive() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        let frame = "content-length: 7\r\n\r\n{\"a\":1}"
        XCTAssertEqual(try dec.feed(Data(frame.utf8)),
                       [Data("{\"a\":1}".utf8)])
    }

    // MARK: - Errors

    func testContentLengthMissingHeaderThrows() {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        XCTAssertThrowsError(try dec.feed(Data("Content-Type: foo\r\n\r\n".utf8))) { err in
            XCTAssertEqual(err as? FrameCodec.DecodeError, .missingContentLength)
        }
    }

    func testContentLengthRejectsOversizedBody() {
        let dec = FrameCodec.Decoder(mode: .contentLength, maxFrameBytes: 100)
        let frame = "Content-Length: 200\r\n\r\n"
        XCTAssertThrowsError(try dec.feed(Data(frame.utf8))) { err in
            guard case .bodyTooLarge(let declared, let max)? = err as? FrameCodec.DecodeError else {
                return XCTFail("expected bodyTooLarge")
            }
            XCTAssertEqual(declared, 200)
            XCTAssertEqual(max, 100)
        }
    }

    func testNDJSONRejectsOversizedFrame() {
        let dec = FrameCodec.Decoder(mode: .ndjson, maxFrameBytes: 5)
        XCTAssertThrowsError(try dec.feed(Data("123456\n".utf8))) { err in
            guard case .bodyTooLarge? = err as? FrameCodec.DecodeError else {
                return XCTFail("expected bodyTooLarge, got \(err)")
            }
        }
    }

    func testBufferOverflowGuard() {
        let dec = FrameCodec.Decoder(mode: .ndjson, maxBufferBytes: 100)
        // Feed bytes that never resolve to a full frame.
        let chunk = Data(repeating: 0x41, count: 200)
        XCTAssertThrowsError(try dec.feed(chunk)) { err in
            guard case .bufferOverflow? = err as? FrameCodec.DecodeError else {
                return XCTFail("expected bufferOverflow")
            }
        }
    }

    // MARK: - Round-trip

    func testEncodeThenDecodeNDJSON() throws {
        let dec = FrameCodec.Decoder(mode: .ndjson)
        let original = Data("{\"hello\":\"world\",\"n\":42}".utf8)
        let framed = FrameCodec.encode(original, mode: .ndjson)
        XCTAssertEqual(try dec.feed(framed), [original])
    }

    func testEncodeThenDecodeContentLength() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        let original = Data("{\"hello\":\"world\",\"n\":42}".utf8)
        let framed = FrameCodec.encode(original, mode: .contentLength)
        XCTAssertEqual(try dec.feed(framed), [original])
    }

    func testEncodeBatchedDecodesEachFrameSeparately() throws {
        let dec = FrameCodec.Decoder(mode: .contentLength)
        let a = Data("{\"i\":1}".utf8)
        let b = Data("{\"i\":2}".utf8)
        let c = Data("{\"i\":3}".utf8)
        var combined = Data()
        combined.append(FrameCodec.encode(a, mode: .contentLength))
        combined.append(FrameCodec.encode(b, mode: .contentLength))
        combined.append(FrameCodec.encode(c, mode: .contentLength))
        XCTAssertEqual(try dec.feed(combined), [a, b, c])
    }
}
