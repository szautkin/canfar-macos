// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class PlatformLoadModelTests: XCTestCase {

    // MARK: - RAM Parsing

    func testParseRamGB_gigabyteSuffixes() {
        XCTAssertEqual(PlatformLoadModel.parseRamGB("16G"), 16.0, accuracy: 0.001)
        XCTAssertEqual(PlatformLoadModel.parseRamGB("16Gi"), 16.0, accuracy: 0.001)
        XCTAssertEqual(PlatformLoadModel.parseRamGB("16GB"), 16.0, accuracy: 0.001)
    }

    func testParseRamGB_megabyteSuffixes() {
        XCTAssertEqual(PlatformLoadModel.parseRamGB("512M"), 0.5, accuracy: 0.001)
        XCTAssertEqual(PlatformLoadModel.parseRamGB("512Mi"), 0.5, accuracy: 0.001)
        XCTAssertEqual(PlatformLoadModel.parseRamGB("1024MB"), 1.0, accuracy: 0.001)
    }

    func testParseRamGB_terabyteSuffixes() {
        XCTAssertEqual(PlatformLoadModel.parseRamGB("2T"), 2048.0, accuracy: 0.001)
        XCTAssertEqual(PlatformLoadModel.parseRamGB("2Ti"), 2048.0, accuracy: 0.001)
        XCTAssertEqual(PlatformLoadModel.parseRamGB("1TB"), 1024.0, accuracy: 0.001)
    }

    func testParseRamGB_plainNumber() {
        XCTAssertEqual(PlatformLoadModel.parseRamGB("32"), 32.0, accuracy: 0.001)
    }

    func testParseRamGB_emptyAndInvalid() {
        XCTAssertEqual(PlatformLoadModel.parseRamGB(""), 0.0)
        XCTAssertEqual(PlatformLoadModel.parseRamGB("abc"), 0.0)
    }

    func testParseRamGB_whitespace() {
        XCTAssertEqual(PlatformLoadModel.parseRamGB("  16G  "), 16.0, accuracy: 0.001)
    }

    // MARK: - CoreStats Flexible Decoding

    func testCoreStatsDecodesFromNumbers() throws {
        let json = #"{"requestedCPUCores": 10.5, "cpuCoresAvailable": 89.5}"#
        let stats = try JSONDecoder().decode(CoreStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.requestedCPUCores, 10.5, accuracy: 0.001)
        XCTAssertEqual(stats.cpuCoresAvailable, 89.5, accuracy: 0.001)
    }

    func testCoreStatsDecodesFromStrings() throws {
        let json = #"{"requestedCPUCores": "10.5", "cpuCoresAvailable": "89.5"}"#
        let stats = try JSONDecoder().decode(CoreStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.requestedCPUCores, 10.5, accuracy: 0.001)
        XCTAssertEqual(stats.cpuCoresAvailable, 89.5, accuracy: 0.001)
    }

    // MARK: - SkahaStatsResponse Optional Fields

    func testStatsResponseDecodesWithAllFields() throws {
        let json = """
        {
            "instances": {"session": 5, "desktopApp": 2, "headless": 1, "total": 8},
            "cores": {"requestedCPUCores": 20, "cpuCoresAvailable": 80},
            "ram": {"requestedRAM": "64G", "ramAvailable": "192G"}
        }
        """
        let stats = try JSONDecoder().decode(SkahaStatsResponse.self, from: Data(json.utf8))

        XCTAssertNotNil(stats.instances)
        XCTAssertEqual(stats.instances?.total, 8)
        XCTAssertEqual(stats.instances?.session, 5)
        XCTAssertEqual(stats.instances?.desktopApp, 2)
        XCTAssertEqual(stats.instances?.headless, 1)

        let cores = try XCTUnwrap(stats.cores)
        XCTAssertEqual(cores.requestedCPUCores, 20.0, accuracy: 0.001)
        XCTAssertEqual(cores.cpuCoresAvailable, 80.0, accuracy: 0.001)

        XCTAssertNotNil(stats.ram)
        XCTAssertEqual(stats.ram?.requestedRAM, "64G")
        XCTAssertEqual(stats.ram?.ramAvailable, "192G")
    }

    func testStatsResponseDecodesWithMissingFields() throws {
        let json = #"{}"#
        let stats = try JSONDecoder().decode(SkahaStatsResponse.self, from: Data(json.utf8))

        XCTAssertNil(stats.instances)
        XCTAssertNil(stats.cores)
        XCTAssertNil(stats.ram)
    }

    func testStatsResponseDecodesFromArray() throws {
        let json = """
        [{"cores": {"requestedCPUCores": 10, "cpuCoresAvailable": 90}}]
        """
        let array = try JSONDecoder().decode([SkahaStatsResponse].self, from: Data(json.utf8))
        XCTAssertEqual(array.count, 1)
        let cores = try XCTUnwrap(array.first?.cores)
        XCTAssertEqual(cores.requestedCPUCores, 10.0, accuracy: 0.001)
    }
}
