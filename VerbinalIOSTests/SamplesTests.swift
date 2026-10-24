// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import VerbinalKit
import XCTest

/// The samples bundled for the first run (plan 49 D4): each one listed is in
/// Verbinal/iOS/Samples, small, whole by its own CHECKSUM and DATASUM, and
/// credits where it came from.
final class SamplesTests: XCTestCase {
    private func url(_ sample: iOSSample) -> URL {
        // …/VerbinalIOSTests/<this file> → the repository → the samples' folder.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Verbinal/iOS/Samples").appendingPathComponent(sample.resource)
    }

    func testEachSampleIsSmallWholeAndCredited() async throws {
        XCTAssertEqual(iOSSample.all.count, 2)
        var total = 0
        for sample in iOSSample.all {
            let url = url(sample)
            let bytes = try Data(contentsOf: url)
            total += bytes.count
            let units = try await FITSCube.parseStructure(source: LocalFileCubeSource(url: url))
            XCTAssertEqual(units.count, 1, sample.resource)
            XCTAssertEqual(FITSVerify.integrity(of: units[0], headerStart: 0, in: bytes), .intact, sample.resource)
            let header = String(decoding: bytes.prefix(2880 * 4), as: UTF8.self)
            XCTAssertTrue(header.contains("Credit: NASA"), "\(sample.resource) credits the observation")
            XCTAssertTrue(header.contains("cut down for Verbinal"), "\(sample.resource) says what was done to it")
        }
        XCTAssertLessThan(total, 2_000_000, "the samples stay under 2 MB together")
    }

    func testTheImageOpensInFITSAndTheCubeInCube() async throws {
        let kinds = try await iOSSample.all.asyncMap { sample in
            let units = try await FITSCube.parseStructure(source: LocalFileCubeSource(url: url(sample)))
            return !FITSCube.findCubeHDUs(units).isEmpty
        }
        XCTAssertEqual(kinds, [false, true])
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
