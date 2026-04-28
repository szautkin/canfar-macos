// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

// MARK: - Rice Unfold Mapping Tests

final class RiceUnfoldTests: XCTestCase {

    /// Verify the fold/unfold mapping: 0→0, 1→−1, 2→1, 3→−2, 4→2, 5→−3, 6→3
    func testUnfoldMapping() {
        let cases: [(Int32, Int32)] = [
            (0, 0),
            (1, -1),
            (2, 1),
            (3, -2),
            (4, 2),
            (5, -3),
            (6, 3),
            (7, -4),
            (8, 4),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(RiceDecoder.unfold(input), expected,
                           "unfold(\(input)) should be \(expected)")
        }
    }

    func testUnfoldLargeEven() {
        // even n → n/2
        XCTAssertEqual(RiceDecoder.unfold(100), 50)
        XCTAssertEqual(RiceDecoder.unfold(1000), 500)
    }

    func testUnfoldLargeOdd() {
        // odd n → −(n+1)/2
        XCTAssertEqual(RiceDecoder.unfold(99), -50)
        XCTAssertEqual(RiceDecoder.unfold(999), -500)
    }
}

// MARK: - BitReader Tests

final class BitReaderTests: XCTestCase {

    func testReadByte() {
        let data = Data([0xAB, 0xCD])
        var reader = BitReader(data: data[0...])
        XCTAssertEqual(reader.readByte(), 0xAB)
        XCTAssertEqual(reader.readByte(), 0xCD)
        XCTAssertNil(reader.readByte())
    }

    func testReadBits_msb_first() {
        // 0b10110100 = 0xB4
        let data = Data([0xB4])
        var reader = BitReader(data: data[0...])
        XCTAssertEqual(reader.readBit(), 1)
        XCTAssertEqual(reader.readBit(), 0)
        XCTAssertEqual(reader.readBit(), 1)
        XCTAssertEqual(reader.readBit(), 1)
        XCTAssertEqual(reader.readBit(), 0)
        XCTAssertEqual(reader.readBit(), 1)
        XCTAssertEqual(reader.readBit(), 0)
        XCTAssertEqual(reader.readBit(), 0)
        XCTAssertNil(reader.readBit())
    }

    func testReadBitsAcrossByteBoundary() {
        // 0xFF 0x00 → bits: 11111111 00000000
        let data = Data([0xFF, 0x00])
        var reader = BitReader(data: data[0...])
        for _ in 0..<8 { XCTAssertEqual(reader.readBit(), 1) }
        for _ in 0..<8 { XCTAssertEqual(reader.readBit(), 0) }
        XCTAssertNil(reader.readBit())
    }

    func testReadByteIsContinuous() {
        // BitReader is continuous — readByte reads 8 bits from wherever the stream is,
        // NOT aligned to byte boundaries.
        // Data: 0b10100000 0xAB(=0b10101011)
        // Bits: 1 0 1 0 0 0 0 0 | 1 0 1 0 1 0 1 1
        // Read 3 bits: 1, 0, 1 → consume bits [0..2]
        // readByte reads next 8 bits [3..10]: 0 0 0 0 0 1 0 1 = 0x05
        let data = Data([0b10100000, 0xAB])
        var reader = BitReader(data: data[0...])
        XCTAssertEqual(reader.readBit(), 1)
        XCTAssertEqual(reader.readBit(), 0)
        XCTAssertEqual(reader.readBit(), 1)
        // readByte is continuous: next 8 bits from position 3
        // bits 3..7 from first byte: 0,0,0,0,0
        // bits 0..2 from 0xAB (0b10101011): 1,0,1
        // combined: 0b00000101 = 0x05
        XCTAssertEqual(reader.readByte(), 0x05)
        // 5 bits remain from 0xAB: bits 3..7 = 0,1,0,1,1
        // readByte needs 8 bits but only 5 remain → padded with zeros
        // 0b01011000 = 0x58
        XCTAssertEqual(reader.readByte(), 0x58)
        XCTAssertNil(reader.readByte())
    }

    func testEmptyStream() {
        let data = Data()
        var reader = BitReader(data: data[0...])
        XCTAssertNil(reader.readByte())
        XCTAssertNil(reader.readBit())
    }
}

// MARK: - Synthetic Tile Decompression Tests

final class RiceDecoderTests: XCTestCase {

    // MARK: - Encoder

    // Encode a tile matching the cfitsio-compatible RiceDecoder:
    //   1. First pixel as 16 bits written into the BIT stream (big-endian, MSB first)
    //   2. For each block (starting at pixel[0]):
    //      a. (fs + 1) written as 4-bit nybble — decoder subtracts 1 to recover fs
    //         Special case: raw nybble 0 → decoder treats as all-zeros block (fs=-1)
    //      b. unary quotient + fs-bit remainder written continuously (NO padding between blocks)
    //   3. Final padding to byte boundary at the very end
    //
    // Note: the first block INCLUDES pixel[0] (delta = 0 since prev = pixel[0]).
    // The decoder reads the literal into prev, then the first block outputs pixel[0].
    private func encodeTile(_ pixels: [Int16], blockSize: Int, fs: Int) -> Data {
        precondition(fs >= 0 && fs <= 14, "fs must be 0-14 for BYTEPIX=2")

        func fold(_ delta: Int32) -> Int32 {
            if delta >= 0 { return delta * 2 }
            else { return -delta * 2 - 1 }
        }

        // Accumulate all bits, then pack into bytes at the end
        var bits: [UInt8] = []

        func writeBits(_ value: Int, count: Int) {
            for b in stride(from: count - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> b) & 1))
            }
        }

        // First pixel: 16 bits into bit stream (big-endian)
        let firstU = UInt16(bitPattern: pixels[0])
        writeBits(Int(firstU), count: 16)

        // The decoder reads the literal into `prev`, then ALL pixelCount pixels
        // come from block iterations — including pixel[0] (whose delta = 0).
        var prev = Int32(pixels[0])
        var i = 0
        while i < pixels.count {
            let blockCount = min(blockSize, pixels.count - i)

            // Write (fs + 1) as 4-bit nybble so decoder recovers fs after subtracting 1.
            writeBits(fs + 1, count: 4)

            // Rice codes for each pixel in the block (no padding between blocks)
            for pi in 0..<blockCount {
                let delta = Int32(pixels[i + pi]) - prev
                let folded = fold(delta)
                let q = Int(folded) >> fs
                let r = Int(folded) & ((1 << fs) - 1)

                // Unary code: q zeros then a 1
                for _ in 0..<q { bits.append(0) }
                bits.append(1)

                // fs remainder bits, MSB first
                if fs > 0 {
                    writeBits(r, count: fs)
                }

                prev = Int32(pixels[i + pi])
            }
            i += blockCount
        }

        // Pad to byte boundary at the very end
        while bits.count % 8 != 0 { bits.append(0) }

        // Pack bits into bytes
        var out = Data()
        var j = 0
        while j < bits.count {
            var byte: UInt8 = 0
            for b in 0..<8 {
                byte |= bits[j + b] << (7 - b)
            }
            out.append(byte)
            j += 8
        }
        return out
    }

    // MARK: - Tests

    func testDecodeAllZeros() throws {
        // All-zero pixel array: first pixel = 0, all deltas = 0
        let pixels = [Int16](repeating: 0, count: 32)
        let compressed = encodeTile(pixels, blockSize: 32, fs: 1)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeConstantValue() throws {
        // All pixels = 100: first pixel = 100, all deltas = 0
        let pixels = [Int16](repeating: 100, count: 16)
        let compressed = encodeTile(pixels, blockSize: 32, fs: 1)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeRamp() throws {
        // Increasing ramp: deltas are all +10 (fold(10)=20, with fs=3: q=2, r=4)
        let pixels: [Int16] = (0..<16).map { Int16($0 * 10) }
        let compressed = encodeTile(pixels, blockSize: 32, fs: 3)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeNegativeDeltas() throws {
        // Decreasing ramp
        let pixels: [Int16] = (0..<16).map { Int16(200 - $0 * 5) }
        let compressed = encodeTile(pixels, blockSize: 32, fs: 3)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeMultipleBlocks() throws {
        // 64 pixels, blockSize=32: exercises the two-block path
        let pixels: [Int16] = (0..<64).map { Int16($0 % 20 - 10) }
        let compressed = encodeTile(pixels, blockSize: 32, fs: 4)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeSinglePixel() throws {
        let pixels: [Int16] = [42]
        let compressed = encodeTile(pixels, blockSize: 32, fs: 2)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: 1, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeEmptyReturnsEmpty() throws {
        let decoded = try RiceDecoder.decode(bytes: Data()[0...],
                                             pixelCount: 0, blockSize: 32)
        XCTAssertEqual(decoded, [])
    }

    func testDecodeBufferUnderrunThrows() {
        // Empty compressed data, but ask for 1 pixel → should throw bufferUnderrun
        let compressed = Data()
        XCTAssertThrowsError(
            try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                   pixelCount: 1, blockSize: 32)
        )
    }

    func testDecodeFs0Mode() throws {
        // fs=0: unary-only coding. All deltas = 0 → each delta encodes as q=0, one '1' bit.
        let pixels = [Int16](repeating: 50, count: 8)
        let compressed = encodeTile(pixels, blockSize: 32, fs: 0)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeFs14Mode() throws {
        // fs=14 is the maximum non-escape value for BYTEPIX=2
        let pixels: [Int16] = [0, 100, -200, 300, -400]
        let compressed = encodeTile(pixels, blockSize: 32, fs: 14)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeNegativeFirstPixel() throws {
        // First pixel is negative — tests 16-bit literal encoding for negative values
        let pixels: [Int16] = [-1000, -990, -980, -970]
        let compressed = encodeTile(pixels, blockSize: 32, fs: 3)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 32)
        XCTAssertEqual(decoded, pixels)
    }

    func testDecodeContinuousBitStream() throws {
        // Encode 3 blocks of 4 pixels each with blockSize=4.
        // The bit stream must be continuous: fs nybble and Rice bits for block N+1
        // immediately follow the last bit of block N with no padding between them.
        let pixels: [Int16] = [0, 1, 2, 3, 10, 11, 12, 13, 100, 101, 102, 103]
        let compressed = encodeTile(pixels, blockSize: 4, fs: 2)
        let decoded = try RiceDecoder.decode(bytes: compressed[compressed.startIndex...],
                                             pixelCount: pixels.count, blockSize: 4)
        XCTAssertEqual(decoded, pixels)
    }
}

// MARK: - FITSDecompressor Integration Tests

final class FITSDecompressorIntegrationTests: XCTestCase {

    // MARK: - Error Cases

    func testUnsupportedCompressionTypeThrows() {
        let hdu = makeCompressedHDU(zcmptype: "GZIP_1")
        let data = Data(repeating: 0, count: 2880)
        XCTAssertThrowsError(try FITSDecompressor.decompress(from: data, hdu: hdu)) { error in
            guard let decomp = error as? FITSDecompressor.Error,
                  case .unsupportedCompression(let t) = decomp else {
                XCTFail("Expected unsupportedCompression, got \(error)")
                return
            }
            XCTAssertEqual(t, "GZIP_1")
        }
    }

    func testHcompressThrows() {
        let hdu = makeCompressedHDU(zcmptype: "HCOMPRESS_1")
        let data = Data(repeating: 0, count: 2880)
        XCTAssertThrowsError(try FITSDecompressor.decompress(from: data, hdu: hdu)) { error in
            guard let decomp = error as? FITSDecompressor.Error,
                  case .unsupportedCompression = decomp else {
                XCTFail("Expected unsupportedCompression, got \(error)")
                return
            }
        }
    }

    func testEmptyZcmptypeThrows() {
        let hdu = makeCompressedHDU(zcmptype: "")
        let data = Data(repeating: 0, count: 2880)
        XCTAssertThrowsError(try FITSDecompressor.decompress(from: data, hdu: hdu)) { error in
            guard let decomp = error as? FITSDecompressor.Error,
                  case .unsupportedCompression = decomp else {
                XCTFail("Expected unsupportedCompression, got \(error)")
                return
            }
        }
    }

    func testUnsupportedBitpixThrows() {
        let hdu = makeCompressedHDU(zcmptype: "RICE_1", zbitpix: 32)
        let data = Data(repeating: 0, count: 2880)
        XCTAssertThrowsError(try FITSDecompressor.decompress(from: data, hdu: hdu)) { error in
            guard let decomp = error as? FITSDecompressor.Error,
                  case .unsupportedBitpix(let bp) = decomp else {
                XCTFail("Expected unsupportedBitpix, got \(error)")
                return
            }
            XCTAssertEqual(bp, 32)
        }
    }

    // MARK: - Variable-Length Descriptor Parsing

    func testMalformedDescriptorThrows() {
        // tableNRows=1 but only 4 bytes of table data (need 8)
        let hdu = makeCompressedHDU(zcmptype: "RICE_1", imageWidth: 4, imageHeight: 1,
                                    tileWidth: 4, tileHeight: 1, tableNRows: 1, tableRowBytes: 8)
        // Provide exactly 4 bytes of table data (truncated descriptor)
        let data = Data(repeating: 0, count: 4)

        // dataOffset is 0, tableRowBytes=8, tableNRows=1 → rowStart=0, needs rowStart+8=8 bytes
        XCTAssertThrowsError(try FITSDecompressor.decompress(from: data, hdu: hdu))
    }

    // MARK: - Round-Trip: Synthetic Compressed FITS

    func testRoundTripSyntheticTile() throws {
        // Build a minimal synthetic compressed FITS in memory:
        // 4x1 image (4 pixels), 1 tile, RICE_1, BITPIX=16, no BSCALE/BZERO
        let imagePixels: [Int16] = [10, 20, 30, 40]
        let compressedTile = encodeRiceTile(imagePixels, blockSize: 32, fs: 2)
        let tileLen = compressedTile.count

        // Binary table:
        //   tableRowBytes = 8 (one 4+4 descriptor)
        //   tableNRows    = 1
        //   heap: the compressed tile bytes
        // Layout: [descriptor (8 bytes)] [heap (tileLen bytes)]
        var tableData = Data()
        // Descriptor row 0: (nelem=tileLen, offset=0)
        tableData.append(contentsOf: bigEndianBytes(Int32(tileLen)))
        tableData.append(contentsOf: bigEndianBytes(Int32(0)))
        // Heap
        tableData.append(contentsOf: compressedTile)

        let hdu = makeCompressedHDU(
            zcmptype: "RICE_1",
            imageWidth: 4, imageHeight: 1,
            tileWidth: 4, tileHeight: 1,
            tableNRows: 1, tableRowBytes: 8,
            pcount: tileLen,
            dataOffset: 0
        )

        let pixels = try FITSDecompressor.decompress(from: tableData, hdu: hdu)
        XCTAssertEqual(pixels.count, 4)
        for (i, expected) in imagePixels.enumerated() {
            XCTAssertEqual(pixels[i], Float(expected), accuracy: 0.01,
                           "pixel[\(i)] mismatch: expected \(expected), got \(pixels[i])")
        }
    }

    func testRoundTripWithBzero() throws {
        // BZERO=32768 is the standard fpack encoding for uint16 images.
        // Physical value = raw + 32768, so raw pixel 0 → physical 32768.
        let imagePixels: [Int16] = [0, 100, -100, 1000]
        let compressedTile = encodeRiceTile(imagePixels, blockSize: 32, fs: 4)
        let tileLen = compressedTile.count

        var tableData = Data()
        tableData.append(contentsOf: bigEndianBytes(Int32(tileLen)))
        tableData.append(contentsOf: bigEndianBytes(Int32(0)))
        tableData.append(contentsOf: compressedTile)

        let hdu = makeCompressedHDU(
            zcmptype: "RICE_1",
            imageWidth: 4, imageHeight: 1,
            tileWidth: 4, tileHeight: 1,
            tableNRows: 1, tableRowBytes: 8,
            pcount: tileLen,
            dataOffset: 0,
            bzero: 32768.0, bscale: 1.0
        )

        let pixels = try FITSDecompressor.decompress(from: tableData, hdu: hdu)
        XCTAssertEqual(pixels.count, 4)
        XCTAssertEqual(pixels[0], 32768.0, accuracy: 0.01)  // 0 + 32768
        XCTAssertEqual(pixels[1], 32868.0, accuracy: 0.01)  // 100 + 32768
        XCTAssertEqual(pixels[2], 32668.0, accuracy: 0.01)  // -100 + 32768
        XCTAssertEqual(pixels[3], 33768.0, accuracy: 0.01)  // 1000 + 32768
    }

    func testRoundTripMultipleTiles() throws {
        // 4x2 image, tileSize=4x1 → 2 tiles
        let row0: [Int16] = [10, 20, 30, 40]
        let row1: [Int16] = [50, 60, 70, 80]
        let tile0 = encodeRiceTile(row0, blockSize: 32, fs: 2)
        let tile1 = encodeRiceTile(row1, blockSize: 32, fs: 2)

        // Table layout: 2 descriptors (16 bytes), then heap with tile0 then tile1
        var tableData = Data()
        // Row 0 descriptor: (len=tile0.count, offset=0)
        tableData.append(contentsOf: bigEndianBytes(Int32(tile0.count)))
        tableData.append(contentsOf: bigEndianBytes(Int32(0)))
        // Row 1 descriptor: (len=tile1.count, offset=tile0.count)
        tableData.append(contentsOf: bigEndianBytes(Int32(tile1.count)))
        tableData.append(contentsOf: bigEndianBytes(Int32(tile0.count)))
        // Heap
        tableData.append(contentsOf: tile0)
        tableData.append(contentsOf: tile1)

        let pcount = tile0.count + tile1.count
        let hdu = makeCompressedHDU(
            zcmptype: "RICE_1",
            imageWidth: 4, imageHeight: 2,
            tileWidth: 4, tileHeight: 1,
            tableNRows: 2, tableRowBytes: 8,
            pcount: pcount,
            dataOffset: 0
        )

        let pixels = try FITSDecompressor.decompress(from: tableData, hdu: hdu)
        XCTAssertEqual(pixels.count, 8)
        // Row 0 (tileIdx=0, tileRow=0, destRowStart=0)
        XCTAssertEqual(pixels[0], 10.0, accuracy: 0.01)
        XCTAssertEqual(pixels[1], 20.0, accuracy: 0.01)
        XCTAssertEqual(pixels[2], 30.0, accuracy: 0.01)
        XCTAssertEqual(pixels[3], 40.0, accuracy: 0.01)
        // Row 1 (tileIdx=1, tileRow=1, destRowStart=4)
        XCTAssertEqual(pixels[4], 50.0, accuracy: 0.01)
        XCTAssertEqual(pixels[5], 60.0, accuracy: 0.01)
        XCTAssertEqual(pixels[6], 70.0, accuracy: 0.01)
        XCTAssertEqual(pixels[7], 80.0, accuracy: 0.01)
    }

    // MARK: - Helpers

    /// Build a Rice-compressed tile matching the cfitsio-compatible RiceDecoder:
    ///   - first pixel as 16 bits into the bit stream (big-endian, MSB first)
    ///   - (fs + 1) as 4-bit nybble for each block (decoder subtracts 1 to recover fs)
    ///   - first block starts at pixel[0] (delta = 0 since prev = pixel[0])
    ///   - Rice bits written continuously across all blocks (no per-block padding)
    ///   - single padding to byte boundary at the end
    private func encodeRiceTile(_ pixels: [Int16], blockSize: Int, fs: Int) -> Data {
        func fold(_ delta: Int32) -> Int32 {
            if delta >= 0 { return delta * 2 }
            else { return -delta * 2 - 1 }
        }

        var bits: [UInt8] = []

        func writeBits(_ value: Int, count: Int) {
            for b in stride(from: count - 1, through: 0, by: -1) {
                bits.append(UInt8((value >> b) & 1))
            }
        }

        // First pixel: 16 bits into bit stream (big-endian, MSB first)
        let firstU = UInt16(bitPattern: pixels[0])
        writeBits(Int(firstU), count: 16)

        // The decoder reads the literal into prev and then outputs ALL pixelCount
        // pixels from block iterations — pixel[0] is the first output (delta = 0).
        var prev = Int32(pixels[0])
        var i = 0
        while i < pixels.count {
            let blockCount = min(blockSize, pixels.count - i)

            // Write (fs + 1) so decoder recovers fs after subtracting 1
            writeBits(fs + 1, count: 4)

            // Rice codes for all pixels in this block, continuously
            for pi in 0..<blockCount {
                let delta = Int32(pixels[i + pi]) - prev
                let folded = fold(delta)
                let q = Int(folded) >> fs
                let r = Int(folded) & ((1 << fs) - 1)

                for _ in 0..<q { bits.append(0) }
                bits.append(1)
                if fs > 0 {
                    writeBits(r, count: fs)
                }

                prev = Int32(pixels[i + pi])
            }
            i += blockCount
        }

        // Pad to byte boundary once at the end
        while bits.count % 8 != 0 { bits.append(0) }

        // Pack bits into bytes
        var out = Data()
        var j = 0
        while j < bits.count {
            var byte: UInt8 = 0
            for b in 0..<8 {
                byte |= bits[j + b] << (7 - b)
            }
            out.append(byte)
            j += 8
        }
        return out
    }

    private func bigEndianBytes(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }

    private func bigEndianInt16Bytes(_ v: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: v)
        return [UInt8(u >> 8), UInt8(u & 0xFF)]
    }

    /// Build a `FITSHDUnit` that looks like a compressed-image extension.
    private func makeCompressedHDU(
        zcmptype: String,
        zbitpix: Int = 16,
        imageWidth: Int = 4,
        imageHeight: Int = 1,
        tileWidth: Int = 4,
        tileHeight: Int = 1,
        tableNRows: Int = 1,
        tableRowBytes: Int = 8,
        pcount: Int = 0,
        dataOffset: Int = 0,
        bzero: Double = 0.0,
        bscale: Double = 1.0
    ) -> FITSHDUnit {
        var h = FITSHeader()
        h.add(FITSCard(keyword: "ZCMPTYPE", value: zcmptype, comment: ""))
        h.add(FITSCard(keyword: "ZBITPIX",  value: String(zbitpix), comment: ""))
        h.add(FITSCard(keyword: "ZNAXIS",   value: "2", comment: ""))
        h.add(FITSCard(keyword: "ZNAXIS1",  value: String(imageWidth), comment: ""))
        h.add(FITSCard(keyword: "ZNAXIS2",  value: String(imageHeight), comment: ""))
        h.add(FITSCard(keyword: "ZTILE1",   value: String(tileWidth), comment: ""))
        h.add(FITSCard(keyword: "ZTILE2",   value: String(tileHeight), comment: ""))
        h.add(FITSCard(keyword: "ZVAL1",    value: "32", comment: "blocksize"))
        h.add(FITSCard(keyword: "ZVAL2",    value: "2", comment: "bytepix"))
        // Private keywords stashed by FITSParser
        h.add(FITSCard(keyword: "_TNAXIS1", value: String(tableRowBytes), comment: ""))
        h.add(FITSCard(keyword: "_TNAXIS2", value: String(tableNRows), comment: ""))
        h.add(FITSCard(keyword: "_PCOUNT",  value: String(pcount), comment: ""))
        h.add(FITSCard(keyword: "_COMPRESSED", value: "T", comment: ""))
        // Patched image dimensions (as FITSParser does)
        h.add(FITSCard(keyword: "NAXIS",    value: "2", comment: ""))
        h.add(FITSCard(keyword: "NAXIS1",   value: String(imageWidth), comment: ""))
        h.add(FITSCard(keyword: "NAXIS2",   value: String(imageHeight), comment: ""))
        h.add(FITSCard(keyword: "BITPIX",   value: String(zbitpix), comment: ""))
        if bzero != 0.0 {
            h.add(FITSCard(keyword: "BZERO", value: String(bzero), comment: ""))
        }
        if bscale != 1.0 {
            h.add(FITSCard(keyword: "BSCALE", value: String(bscale), comment: ""))
        }

        return FITSHDUnit(
            id: 1,
            header: h,
            dataOffset: dataOffset,
            dataLength: tableRowBytes * tableNRows + pcount,
            wcs: nil
        )
    }
}
