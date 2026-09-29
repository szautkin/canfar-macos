// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// fpack RICE_1 files as cfitsio writes them, decoded value for value
/// against the same images uncompressed. Their noise rows are compressed
/// in high-entropy blocks — raw values, not Rice codes — which the decoder
/// once read as codes, so every CFHT frame came out as streaks.
final class RiceFixtureTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"), name)
        return try Data(contentsOf: url)
    }

    /// The plain file's stored integers, as written: big-endian, BITPIX wide.
    private func plainValues(_ name: String) throws -> (values: [Int64], width: Int, height: Int) {
        let data = try fixture(name)
        let hdu = try XCTUnwrap(try FITSParser.parse(from: data).hdus.first)
        let width = hdu.header.naxis1, height = hdu.header.naxis2
        let bytes = abs(hdu.header.bitpix) / 8
        let values = (0..<(width * height)).map { index -> Int64 in
            let start = hdu.dataOffset + index * bytes
            let raw = data[start..<(start + bytes)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            switch bytes {
            case 1: return Int64(UInt8(raw))
            case 2: return Int64(Int16(bitPattern: UInt16(raw)))
            default: return Int64(Int32(bitPattern: UInt32(raw)))
            }
        }
        return (values, width, height)
    }

    private func assertDecodesAsPlain(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let packed = try fixture(name + ".fits.fz")
        let hdu = try XCTUnwrap(try FITSParser.parse(from: packed).firstImageHDU, file: file, line: line)
        let decoded = try FITSDecompressor.storedValues(from: packed, hdu: hdu).map(Int64.init)
        let plain = try plainValues(name + ".fits")
        XCTAssertEqual(decoded.count, plain.values.count, file: file, line: line)
        let firstWrong = zip(decoded, plain.values).enumerated().first { $0.element.0 != $0.element.1 }
        XCTAssertNil(firstWrong.map { "pixel (\($0.offset % plain.width), \($0.offset / plain.width)): \($0.element.0) ≠ \($0.element.1)" },
                     name, file: file, line: line)
    }

    func testSixteenBitRowTilesAsCFHTWritesThem() throws { try assertDecodesAsPlain("rice16") }

    func testSixteenBitSquareTiles() throws { try assertDecodesAsPlain("rice16tiles") }

    func testThirtyTwoBitTiles() throws { try assertDecodesAsPlain("rice32") }

    func testEightBitTiles() throws { try assertDecodesAsPlain("rice8") }

    /// QA regression run, H1: CFHT's frames name no BYTEPIX, and cfitsio then
    /// takes 4 — a 16-bit image Rice-coded as 32-bit integers. Read as 2,
    /// every tile ran out ("compressed data ended unexpectedly").
    func testSixteenBitImageWithoutBytepixIsThirtyTwoBitRice() throws {
        try assertDecodesAsPlain("rice16nobytepix")
        let table = try FITSParser.parse(from: try fixture("rice16nobytepix.fits.fz")).hdus[1]
        XCTAssertEqual(table.compression?.bytePix, 4, "the default is 4, as FITS 4.0 and cfitsio have it")
    }

    /// What the viewer shows: BZERO 32768 turns the stored int16 back into the unsigned counts.
    func testPixelsAreThePlainFilesValues() throws {
        let packed = try fixture("rice16.fits.fz")
        let plain = try fixture("rice16.fits")
        let packedHDU = try XCTUnwrap(try FITSParser.parse(from: packed).firstImageHDU)
        let plainHDU = try XCTUnwrap(try FITSParser.parse(from: plain).firstImageHDU)
        XCTAssertEqual(try FITSParser.extractPixels(from: packed, hdu: packedHDU),
                       try FITSParser.extractPixels(from: plain, hdu: plainHDU))
    }

    /// A local cutout of an fpack image is written at the image's own width:
    /// its bytes are the plain file's bytes of the same box, 8, 16 or 32 bits.
    func testACutoutOfEachWidthIsThePlainFilesBytes() throws {
        let box = PixelBox(x0: 5, y0: 28, x1: 45, y1: 40)   // across the ramp and the noise
        for name in ["rice8", "rice16", "rice32"] {
            let packed = try fixture(name + ".fits.fz")
            let plain = try fixture(name + ".fits")
            let packedHDU = try XCTUnwrap(try FITSParser.parse(from: packed).firstImageHDU)
            let plainHDU = try XCTUnwrap(try FITSParser.parse(from: plain).firstImageHDU)
            XCTAssertEqual(try FITSCutter.pixels(of: packedHDU, box: box, in: packed),
                           try FITSCutter.pixels(of: plainHDU, box: box, in: plain), name)
        }
    }
}

/// A compressed image's header is the image's, as cfitsio presents it —
/// not the table's cards with the image's appended to them.
final class TileCompressionHeaderTests: XCTestCase {

    func testTheHeaderIsTheImagesOnceEach() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rice16.fits.fz", withExtension: nil, subdirectory: "Fixtures"))
        let hdu = try XCTUnwrap(try FITSParser.parse(from: Data(contentsOf: url)).firstImageHDU)
        let keywords = hdu.header.orderedCards.map(\.keyword)
        XCTAssertEqual(Array(keywords.prefix(6)), ["XTENSION", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "PCOUNT"])
        XCTAssertEqual(hdu.header.string("XTENSION"), "IMAGE")
        XCTAssertEqual([hdu.header.bitpix, hdu.header.naxis1, hdu.header.naxis2], [16, 64, 48])
        for keyword in ["BITPIX", "NAXIS1", "NAXIS2", "EXTNAME", "BZERO"] where keywords.contains(keyword) {
            XCTAssertEqual(keywords.filter { $0 == keyword }.count, 1, keyword)
        }
        XCTAssertFalse(keywords.contains { $0.hasPrefix("ZTILE") || $0.hasPrefix("TFORM") || $0 == "ZCMPTYPE" || $0.hasPrefix("_") })
        XCTAssertEqual(hdu.header.bzero, 32768)
        let layout = try XCTUnwrap(hdu.compression)
        XCTAssertEqual([layout.tileWidth, layout.tileHeight, layout.blockSize, layout.bytePix, layout.rows], [64, 1, 32, 2, 48])
    }

    func testEachCardHasOneFate() {
        XCTAssertEqual(TileCompression.fate(of: "ZBLANK"), .rename("BLANK"))
        for dropped in ["ZTILE1", "ZNAXIS2", "TFORM1", "TTYPE1", "ZCMPTYPE", "ZQUANTIZ", "CHECKSUM", "ZHECKSUM", "NAXIS1", "THEAP"] {
            XCTAssertEqual(TileCompression.fate(of: dropped), .drop, dropped)
        }
        for kept in ["EXTNAME", "BZERO", "CRVAL1", "OBJECT", "ZD", "ZTILEX", "HISTORY"] {
            XCTAssertEqual(TileCompression.fate(of: kept), .keep, kept)
        }
    }
}
