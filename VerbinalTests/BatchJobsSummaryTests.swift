// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Batch Jobs always says every count, zeros too, so an empty queue is not
/// taken for a view that has not loaded (plan 17 U2, QA N12).
@MainActor
final class BatchJobsSummaryTests: XCTestCase {

    func testEveryCountIsSaidZerosIncluded() {
        let model = HeadlessMonitorModel(headlessService: HeadlessService(network: NetworkClient(session: MockURLProtocol.mockSession())))
        XCTAssertEqual(model.statusSummary, "0 running · 0 pending · 0 done · 0 failed")
        model.completedCount = 1
        model.failedCount = 1
        XCTAssertEqual(model.statusSummary, "0 running · 0 pending · 1 done · 1 failed")
        XCTAssertEqual(model.statusCounts.map(\.status), [.running, .pending, .done, .failed])
    }
}
