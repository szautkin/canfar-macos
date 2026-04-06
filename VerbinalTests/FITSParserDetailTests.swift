// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class FITSParserDetailTests: XCTestCase {

    // MARK: - Pixel Extraction

    func testExtractPixelsInt16() {
        // Create a synthetic 2x2 INT16 HDU
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "16", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "2", comment: ""))

        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 8, wcs: nil)

        // 4 big-endian INT16 values: 100, 200, 300, 400
        var rawData = Data()
        for v: Int16 in [100, 200, 300, 400] {
            var bigEndian = v.bigEndian
            rawData.append(Data(bytes: &bigEndian, count: 2))
        }

        let pixels = try! FITSParser.extractPixels(from: rawData, hdu: hdu)
        XCTAssertEqual(pixels.count, 4)
        XCTAssertEqual(pixels[0], 100.0, accuracy: 0.001)
        XCTAssertEqual(pixels[1], 200.0, accuracy: 0.001)
        XCTAssertEqual(pixels[2], 300.0, accuracy: 0.001)
        XCTAssertEqual(pixels[3], 400.0, accuracy: 0.001)
    }

    func testExtractPixelsWithBscaleBzero() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "16", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "1", comment: ""))
        header.add(FITSCard(keyword: "BSCALE", value: "2.0", comment: ""))
        header.add(FITSCard(keyword: "BZERO", value: "100.0", comment: ""))

        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 4, wcs: nil)

        // 2 big-endian INT16 values: 10, 20
        var rawData = Data()
        for v: Int16 in [10, 20] {
            var bigEndian = v.bigEndian
            rawData.append(Data(bytes: &bigEndian, count: 2))
        }

        let pixels = try! FITSParser.extractPixels(from: rawData, hdu: hdu)
        // physical = BZERO + BSCALE * raw = 100 + 2*10 = 120, 100 + 2*20 = 140
        XCTAssertEqual(pixels[0], 120.0, accuracy: 0.1)
        XCTAssertEqual(pixels[1], 140.0, accuracy: 0.1)
    }

    func testExtractPixelsUInt8() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "8", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "3", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "1", comment: ""))

        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 3, wcs: nil)
        let rawData = Data([0, 128, 255])

        let pixels = try! FITSParser.extractPixels(from: rawData, hdu: hdu)
        XCTAssertEqual(pixels.count, 3)
        XCTAssertEqual(pixels[0], 0.0)
        XCTAssertEqual(pixels[1], 128.0)
        XCTAssertEqual(pixels[2], 255.0)
    }

    func testExtractPixelsUnsupportedBitpixThrows() {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "BITPIX", value: "128", comment: ""))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: ""))
        header.add(FITSCard(keyword: "NAXIS1", value: "1", comment: ""))
        header.add(FITSCard(keyword: "NAXIS2", value: "1", comment: ""))

        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 16, wcs: nil)
        let rawData = Data(repeating: 0, count: 16)

        XCTAssertThrowsError(try FITSParser.extractPixels(from: rawData, hdu: hdu)) { error in
            if case FITSError.unsupportedBitpix(let bp) = error {
                XCTAssertEqual(bp, 128)
            } else {
                XCTFail("Expected unsupportedBitpix, got \(error)")
            }
        }
    }

    // MARK: - Stretch Functions via Render Engine

    func testAllStretchModesProduceImage() {
        let pixels: [Float] = (0..<16).map { Float($0) }
        for stretch in FITSRenderParams.StretchMode.allCases {
            let params = FITSRenderParams(minCut: 0, maxCut: 15, stretch: stretch, colormap: .grayscale)
            let image = FITSRenderEngine.render(pixels: pixels, width: 4, height: 4, params: params)
            XCTAssertNotNil(image, "Stretch \(stretch.rawValue) should produce non-nil image")
        }
    }

    func testAllColormapsProduceImage() {
        let pixels: [Float] = (0..<16).map { Float($0) }
        for colormap in FITSRenderParams.ColormapType.allCases {
            let params = FITSRenderParams(minCut: 0, maxCut: 15, stretch: .linear, colormap: colormap)
            let image = FITSRenderEngine.render(pixels: pixels, width: 4, height: 4, params: params)
            XCTAssertNotNil(image, "Colormap \(colormap.rawValue) should produce non-nil image")
        }
    }
}
