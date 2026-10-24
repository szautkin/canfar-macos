// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// Moment 0, a plane at a time (plan 47 5.5).
final class CubeMomentTests: XCTestCase {
    func testSumsTheFiniteValuesTimesTheChannelWidth() {
        var moment = CubeMoment0(spaxels: 3)
        moment.add([1, .nan, 2])
        moment.add([3, .nan, .nan])
        moment.add([.infinity, .nan, 4])
        XCTAssertEqual(moment.planes, 3)
        let map = moment.map(channelWidth: -0.5)
        XCTAssertEqual(map[0], 2, "(1 + 3) × |−0.5|; an infinity is not a value")
        XCTAssertTrue(map[1].isNaN, "blank in every channel stays blank")
        XCTAssertEqual(map[2], 3)
    }

    func testAnUnknownWidthCountsAsOne() {
        var moment = CubeMoment0(spaxels: 1)
        moment.add([5])
        XCTAssertEqual(moment.map(channelWidth: 0), [5])
    }
}
