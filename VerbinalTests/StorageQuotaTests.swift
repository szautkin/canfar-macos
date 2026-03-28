// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class StorageQuotaTests: XCTestCase {

    func testQuotaGB() {
        let quota = StorageQuota(quotaBytes: 1_073_741_824, usedBytes: 0)
        XCTAssertEqual(quota.quotaGB, 1.0, accuracy: 0.001)
    }

    func testUsedGB() {
        let quota = StorageQuota(quotaBytes: 0, usedBytes: 536_870_912)
        XCTAssertEqual(quota.usedGB, 0.5, accuracy: 0.001)
    }

    func testUsagePercent() {
        let quota = StorageQuota(quotaBytes: 1_073_741_824, usedBytes: 536_870_912)
        XCTAssertEqual(quota.usagePercent, 50.0, accuracy: 0.001)
    }

    func testUsagePercentWithZeroQuota() {
        let quota = StorageQuota(quotaBytes: 0, usedBytes: 100)
        XCTAssertEqual(quota.usagePercent, 0.0)
    }

    func testLargeQuota() {
        let quota = StorageQuota(quotaBytes: 107_374_182_400, usedBytes: 53_687_091_200)
        XCTAssertEqual(quota.quotaGB, 100.0, accuracy: 0.001)
        XCTAssertEqual(quota.usedGB, 50.0, accuracy: 0.001)
        XCTAssertEqual(quota.usagePercent, 50.0, accuracy: 0.001)
    }
}
