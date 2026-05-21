// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Coverage for the applier watchdog primitive. The function is a
/// load-bearing safety net — it's what guarantees a hung applier
/// (F-2026-05-13-A from the QA log) always surfaces as
/// `proposalRejected` instead of an invisible silent stall, so it's
/// worth pinning the three observable behaviours under test.
final class ApplierTimeoutTests: XCTestCase {

    /// Work that completes well inside the deadline returns its
    /// value verbatim. The watchdog must not interfere with the
    /// happy path.
    func testFastWorkPassesThrough() async throws {
        let value = try await withApplierTimeout(seconds: 5, label: "fast") {
            return 42
        }
        XCTAssertEqual(value, 42)
    }

    /// Work that takes longer than the deadline throws a
    /// `ProposalApplyError.backendError` whose message names the
    /// label and the budget. The dispatch path (AgentsService)
    /// pattern-matches on this type to emit `proposalRejected`.
    func testSlowWorkRaisesTypedTimeoutError() async {
        do {
            _ = try await withApplierTimeout(seconds: 0.2, label: "slow_op") {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 99
            }
            XCTFail("expected timeout to throw")
        } catch let pa as ProposalApplyError {
            switch pa {
            case .backendError(let msg):
                XCTAssertTrue(msg.contains("slow_op"), "label must appear in the message; got: \(msg)")
                XCTAssertTrue(msg.contains("deadline"), "deadline language must appear; got: \(msg)")
            case .noApplierForKind:
                XCTFail("wrong typed case: \(pa)")
            }
        } catch {
            XCTFail("expected ProposalApplyError, got: \(error)")
        }
    }

    /// Errors thrown by the work closure pass through untouched —
    /// the watchdog adds a deadline, it does not rewrap business
    /// failures. Pins that the caller's `catch let pa as
    /// ProposalApplyError` arm still sees real applier errors.
    func testWorkErrorsPassThrough() async {
        struct AppFailure: Error, Equatable { let code: Int }
        do {
            _ = try await withApplierTimeout(seconds: 5, label: "passthrough") {
                throw AppFailure(code: 42)
            }
            XCTFail("expected work error to throw")
        } catch let f as AppFailure {
            XCTAssertEqual(f.code, 42)
        } catch {
            XCTFail("expected AppFailure verbatim, got: \(error)")
        }
    }
}
