// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// What an image's picture is drawn at, and whether its pixels fit in the
/// memory free — the limits that replaced 4 GB and 500 Mpx.
final class FITSDisplayLimitsTests: XCTestCase {

    // MARK: - The picture

    func testAnImageThatFitsIsItsOwnPicture() {
        XCTAssertEqual(FITSDisplayRaster.scale(width: 11471, height: 4593), 1, "the mosaics that already opened")
        let pixels: [Float] = [1, 2, 3, 4]
        let picture = FITSDisplayRaster.picture(of: pixels, width: 2, height: 2)
        XCTAssertEqual(picture.pixels, pixels)
        XCTAssertEqual([picture.width, picture.height], [2, 2])
    }

    func testAMegaPipeTileIsDrawnWithinTheLimits() {
        let scale = FITSDisplayRaster.scale(width: 20315, height: 20475)
        let w = Int(20315 * scale + 1e-6), h = Int(20475 * scale + 1e-6)
        XCTAssertLessThanOrEqual(w * h, FITSDisplayRaster.maxPixels)
        XCTAssertLessThanOrEqual(max(w, h), FITSDisplayRaster.maxSide)
        XCTAssertEqual(Int((40000 * FITSDisplayRaster.scale(width: 40000, height: 100)).rounded()), FITSDisplayRaster.maxSide,
                       "a long strip is held to the texture's side")
    }

    /// A star one pixel across survives as part of its block's mean; blanks
    /// are left out of it, and a block of nothing but blanks stays blank.
    func testThePictureIsABlockAverageThatKeepsStarsAndBlanks() {
        let nan = Float.nan
        let pixels: [Float] = [
            0, 0, nan, nan,
            0, 8, nan, nan,
            1, 1, 2, nan,
            1, 1, nan, nan,
        ]
        let picture = FITSDisplayRaster.picture(of: pixels, width: 4, height: 4, maxPixels: 4)
        XCTAssertEqual([picture.width, picture.height], [2, 2])
        XCTAssertEqual(picture.pixels[0], 2, "the star, spread over its block")
        XCTAssertTrue(picture.pixels[1].isNaN)
        XCTAssertEqual(picture.pixels[2], 1)
        XCTAssertEqual(picture.pixels[3], 2, "only the finite pixel counts")
    }

    func testUnevenBlocksStillCoverEveryPixel() {
        let pixels = (0..<(6 * 3)).map(Float.init)
        let picture = FITSDisplayRaster.picture(of: pixels, width: 6, height: 3, maxPixels: 2)
        XCTAssertLessThanOrEqual(picture.width * picture.height, 2)
        XCTAssertFalse(picture.pixels.contains { $0.isNaN })
        XCTAssertEqual(picture.pixels.reduce(0, +) / Float(picture.pixels.count), pixels.reduce(0, +) / Float(pixels.count),
                       accuracy: 0.001, "equal blocks keep the image's mean")
    }

    // MARK: - The memory

    func testTheFloorIsAlwaysAllowedAndAboveItTheMemoryFreeDecides() {
        XCTAssertNil(FITSMemoryBudget.refusal(width: 8000, height: 8000, availableBytes: 0), "256 MB is under the floor")
        XCTAssertEqual(FITSMemoryBudget.maxImageBytes(availableBytes: 0), FITSMemoryBudget.floor)
        let twenty = Int64(20) * 1024 * 1024 * 1024
        XCTAssertNil(FITSMemoryBudget.refusal(width: 20315, height: 20475, availableBytes: twenty), "1.6 GB with 20 GB free")
        let refusal = try? XCTUnwrap(FITSMemoryBudget.refusal(width: 20315, height: 20475, availableBytes: 1024 * 1024 * 1024))
        XCTAssertTrue(refusal?.filter(\.isNumber).hasPrefix("2031520475") == true, "its size, in the reader's own digits: \(refusal ?? "")")
        XCTAssertTrue(refusal?.contains("cutout") == true)
        XCTAssertNotNil(FITSMemoryBudget.refusal(width: .max, height: 3, availableBytes: twenty), "dimensions that overflow")
        XCTAssertGreaterThan(FITSMemoryBudget.availableBytes(), 0)
    }
}
