// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// A figure export answers with the file it wrote (plan 17 A3, QA N8:
/// the PDF could be found only by listing Downloads).
final class FigureExportApplierTests: XCTestCase {

    private struct Request: Codable, Sendable { let scale: Int }

    func testTheAnswerNamesTheFileWritten() async throws {
        let applier = FigureExportApplier<Request>(
            kind: "export_fits_figure", run: { request in "/Users/u/Downloads/figure-\(request.scale)x.png" },
            activity: await AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "export_fits_figure", kind: "export_fits_figure", summary: "Export",
                                       payload: try JSONEncoder().encode(Request(scale: 2)), origin: .external(clientID: "t"))
        let extra = try JSONDecoder().decode(AutoAppliedAck.Extra.self, from: try await applier.applyReturningResult(proposal))
        XCTAssertEqual(extra.file, "/Users/u/Downloads/figure-2x.png")
    }

    func testAFailureSaysWhy() async throws {
        struct Broken: LocalizedError { var errorDescription: String? { "No FITS tab is open" } }
        let applier = FigureExportApplier<Request>(
            kind: "export_fits_figure", run: { _ in throw Broken() },
            activity: await AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "export_fits_figure", kind: "export_fits_figure", summary: "Export",
                                       payload: try JSONEncoder().encode(Request(scale: 1)), origin: .external(clientID: "t"))
        do {
            _ = try await applier.applyReturningResult(proposal)
            XCTFail("it throws")
        } catch let ProposalApplyError.backendError(message) {
            XCTAssertTrue(message.contains("No FITS tab is open"), message)
        }
    }
}
