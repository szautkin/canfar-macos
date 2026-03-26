// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
