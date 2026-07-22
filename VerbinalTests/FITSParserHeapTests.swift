// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
import VerbinalKit

/// Regression tests for the HDU byte-offset walk across a data segment that
/// carries a PCOUNT heap (as a tile-compressed / fpack BINTABLE does). Before
/// the fix, `dataLength` omitted PCOUNT/GCOUNT, so the next-HDU offset landed
/// mid-heap and every trailing extension in a multi-extension MEF was lost.
final class FITSParserHeapTests: XCTestCase {

    // MARK: - Synthetic FITS builders (2880-byte blocks, 80-char cards)

    /// One 80-character FITS card. Keyword in cols 1–8, "= " in cols 9–10.
    private func card(_ keyword: String, _ value: String) -> String {
        let kw = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        return "\(kw)= \(value)".padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    /// Assemble the given cards + an END card into a block-aligned header
    /// (padded with blank cards so the total is a multiple of 2880 bytes).
    private func headerBlock(_ cards: [String]) -> Data {
        var all = cards
        all.append("END".padding(toLength: 80, withPad: " ", startingAt: 0))
        let padCards = (36 - (all.count % 36)) % 36
        for _ in 0..<padCards { all.append(String(repeating: " ", count: 80)) }
        return all.joined().data(using: .ascii)!
    }

    /// Pad a data segment up to the next 2880-byte boundary (FITS convention).
    private func padData(_ data: Data) -> Data {
        var d = data
        let remainder = d.count % 2880
        if remainder != 0 { d.append(Data(repeating: 0, count: 2880 - remainder)) }
        return d
    }

    // MARK: - (a) BINTABLE with a PCOUNT heap, then a trailing IMAGE

    func testTrailingHDUAfterPcountHeapIsNotDropped() throws {
        // Primary: NAXIS=0, no data.
        let primary = headerBlock([
            card("SIMPLE", "T"),
            card("BITPIX", "8"),
            card("NAXIS", "0"),
        ])

        // BINTABLE-like HDU: NAXIS1=8 bytes/row × NAXIS2=1 row = 8 table bytes,
        // plus a PCOUNT=5752-byte heap. dataLength per FITS 4.4.1 is
        //   (8/8) × max(1, GCOUNT) × (PCOUNT + NAXIS1·NAXIS2)
        //   = 1 × 1 × (5752 + 8) = 5760 bytes = exactly 2 blocks.
        // Omitting PCOUNT would give 8 bytes → 1 block, landing the next-HDU
        // offset in the middle of the (space-filled) heap, where the parser
        // sees a blank card and stops — dropping the trailing IMAGE below.
        let bintable = headerBlock([
            card("XTENSION", "'BINTABLE'"),
            card("BITPIX", "8"),
            card("NAXIS", "2"),
            card("NAXIS1", "8"),
            card("NAXIS2", "1"),
            card("PCOUNT", "5752"),
            card("GCOUNT", "1"),
        ])
        // Table + heap = 5760 bytes; fill with spaces so a wrong (too-early)
        // offset resolves to a blank card and the buggy walk halts cleanly.
        let bintableData = Data(repeating: 0x20, count: 5760)

        // Trailing IMAGE with distinctive 7×5 dims so its presence is unambiguous.
        let trailing = headerBlock([
            card("XTENSION", "'IMAGE'"),
            card("BITPIX", "8"),
            card("NAXIS", "2"),
            card("NAXIS1", "7"),
            card("NAXIS2", "5"),
            card("PCOUNT", "0"),
            card("GCOUNT", "1"),
        ])
        let trailingData = padData(Data(repeating: 0, count: 7 * 5))

        var file = Data()
        file.append(primary)
        file.append(bintable)
        file.append(bintableData)
        file.append(trailing)
        file.append(trailingData)

        let parsed = try FITSParser.parse(from: file)

        XCTAssertEqual(parsed.hdus.count, 3, "Primary + BINTABLE + trailing IMAGE must all be parsed")
        // The heap must be counted in the BINTABLE's dataLength.
        XCTAssertEqual(parsed.hdus[1].dataLength, 5760,
                       "BINTABLE dataLength must include the PCOUNT heap (5752 + 8 table bytes)")
        // The trailing IMAGE must survive with its exact dimensions.
        let image = parsed.hdus[2]
        XCTAssertEqual(image.header.naxis, 2)
        XCTAssertEqual(image.header.naxis1, 7)
        XCTAssertEqual(image.header.naxis2, 5)
    }

    // MARK: - (b) NAXIS=3 cube, then a trailing IMAGE (no heap — must be unchanged)

    func testNaxis3CubeThenTrailingImageBothPresent() throws {
        // Primary is a 4×3×4 Int16 cube (WFPC2-style multi-plane). With no
        // PCOUNT and no GCOUNT, dataLength = (16/8) × 1 × (0 + 4·3·4) = 96 bytes,
        // identical to the pre-fix result — this locks the no-regression case.
        let cube = headerBlock([
            card("SIMPLE", "T"),
            card("BITPIX", "16"),
            card("NAXIS", "3"),
            card("NAXIS1", "4"),
            card("NAXIS2", "3"),
            card("NAXIS3", "4"),
        ])
        let cubeData = padData(Data(repeating: 0, count: 2 * 4 * 3 * 4)) // 96 bytes → 1 block

        let trailing = headerBlock([
            card("XTENSION", "'IMAGE'"),
            card("BITPIX", "16"),
            card("NAXIS", "2"),
            card("NAXIS1", "2"),
            card("NAXIS2", "2"),
            card("PCOUNT", "0"),
            card("GCOUNT", "1"),
        ])
        let trailingData = padData(Data(repeating: 0, count: 2 * 2 * 2))

        var file = Data()
        file.append(cube)
        file.append(cubeData)
        file.append(trailing)
        file.append(trailingData)

        let parsed = try FITSParser.parse(from: file)

        XCTAssertEqual(parsed.hdus.count, 2, "Cube + trailing IMAGE must both be parsed")
        let cubeHDU = parsed.hdus[0]
        XCTAssertEqual(cubeHDU.header.naxis, 3)
        XCTAssertEqual(cubeHDU.header.naxis1, 4)
        XCTAssertEqual(cubeHDU.header.naxis2, 3)
        XCTAssertEqual(cubeHDU.header.int("NAXIS3"), 4)
        XCTAssertEqual(cubeHDU.dataLength, 96, "Plain cube dataLength must be unchanged (2 × 4·3·4)")
        XCTAssertEqual(parsed.hdus[1].header.naxis, 2)
    }
}
