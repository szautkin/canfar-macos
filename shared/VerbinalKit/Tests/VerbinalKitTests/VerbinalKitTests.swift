// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

final class VerbinalKitSmokeTests: XCTestCase {
    func testPackageVersionIsNotEmpty() {
        XCTAssertFalse(VerbinalKit.version.isEmpty)
    }
}
