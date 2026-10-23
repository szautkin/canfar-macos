// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import VerbinalKit
import XCTest

/// The FITS viewer's Verify (plan 47 4.3): a file's checksums from its own
/// bytes, and its values.
final class FITSVerifyTests: XCTestCase {
    private func card(_ text: String) -> String { text.padding(toLength: 80, withPad: " ", startingAt: 0) }

    /// A one-HDU file of eight bytes, with a DATASUM and a CHECKSUM made as
    /// Verbinal's own cutouts make them.
    private func file() -> Data {
        var data = Data([1, 2, 3, 4, 5, 6, 7, 8])
        data.append(Data(count: 2880 - data.count))
        let dataSum = FITSChecksum.sum(data)
        func header(checksum: String) -> Data {
            var text = [card("SIMPLE  =                    T"), card("BITPIX  =                    8"),
                        card("NAXIS   =                    1"), card("NAXIS1  =                    8"),
                        card("DATASUM = '\(dataSum)'"), card("CHECKSUM= '\(checksum)'"), card("END")].joined()
            text += String(repeating: " ", count: 2880 - text.count)
            return Data(text.utf8)
        }
        let checksum = FITSChecksum.encode(FITSChecksum.add(FITSChecksum.sum(header(checksum: "0000000000000000")), dataSum))
        return header(checksum: checksum) + data
    }

    private func hdus(_ bytes: Data) async throws -> [FITSHDUnit] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await FITSCube.parseStructure(source: LocalFileCubeSource(url: url))
    }

    func testAWholeFileIsIntact() async throws {
        let bytes = file()
        let units = try await hdus(bytes)
        XCTAssertEqual(FITSVerify.headerStarts(units), [0])
        XCTAssertEqual(FITSVerify.integrity(of: units[0], headerStart: 0, in: bytes), .intact)
    }

    func testAChangedByteIsCaught() async throws {
        var bytes = file()
        let units = try await hdus(bytes)
        bytes[2880 + 3] ^= 0xFF
        guard case .damaged = FITSVerify.integrity(of: units[0], headerStart: 0, in: bytes) else {
            return XCTFail("a changed data byte must not pass")
        }
    }

    func testValues() {
        let stats = FITSVerify.stats([1, 2, 3, .nan, 4, 10], saturate: 4)
        XCTAssertEqual(stats.count, 6)
        XCTAssertEqual(stats.blank, 1)
        XCTAssertEqual(stats.min, 1)
        XCTAssertEqual(stats.max, 10)
        XCTAssertEqual(stats.mean, 4, accuracy: 1e-9)
        XCTAssertEqual(stats.median, 3)
        XCTAssertEqual(stats.saturated, 2)
        XCTAssertFalse(stats.medianSampled)
    }

    func testPercentileCutAndHistogram() throws {
        let values = (0..<1000).map(Float.init)
        let cut = try XCTUnwrap(FITSVerify.percentileCut(values, kept: 0.99))
        XCTAssertEqual(cut.min, 4)
        XCTAssertEqual(cut.max, 994)
        XCTAssertEqual(FITSVerify.histogram((0..<10).map(Float.init), lo: 0, hi: 10, bins: 10), Array(repeating: 1, count: 10))
        XCTAssertNil(FITSVerify.percentileCut([5, 5, 5], kept: 0.99), "no spread, no cut")
    }
}
