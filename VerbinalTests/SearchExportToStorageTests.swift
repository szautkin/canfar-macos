// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 36 2.11 (flow review G1): a search export can go to the person's
/// storage — where, and whether a copy stays on the Mac, said before the
/// person approves it and in the answer.
@MainActor
final class SearchExportToStorageTests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/verbinal-results-1.csv")
    private let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))

    func testAResultGoesToTheFolderOrTheFileNamed() throws {
        XCTAssertEqual(try ResultUpload.remotePath(for: file, in: nil, username: "me"), "Verbinal-Exports/verbinal-results-1.csv")
        XCTAssertEqual(try ResultUpload.remotePath(for: file, in: "  ", username: "me"), "Verbinal-Exports/verbinal-results-1.csv")
        XCTAssertEqual(try ResultUpload.remotePath(for: file, in: "projects/m31/", username: "me"), "projects/m31/verbinal-results-1.csv")
        XCTAssertEqual(try ResultUpload.remotePath(for: file, in: "/arc/home/me/projects/m31", username: "me"), "projects/m31/verbinal-results-1.csv")
        XCTAssertEqual(try ResultUpload.remotePath(for: file, in: "projects/targets.CSV", username: "me"), "projects/targets.CSV")
        XCTAssertEqual(try ResultUpload.remotePath(for: file, in: "home/me", username: "me"), "verbinal-results-1.csv")
        XCTAssertThrowsError(try ResultUpload.remotePath(for: file, in: "../them", username: "me"))
    }

    func testTheProposalSaysWhereTheFileGoes() async throws {
        let tool = ExportSearchResultsTool()
        let plain = try await tool.plan(.init(format: "csv"), context: ctx)
        XCTAssertEqual(plain.summary, "Export search results as CSV to Downloads")

        let both = try await tool.plan(.init(format: "csv", uploadToVOSpace: true), context: ctx)
        XCTAssertEqual(both.summary, "Export search results as CSV to Downloads and storage (Verbinal-Exports/)")

        let only = try await tool.plan(.init(format: "votable", vospacePath: "projects/m31", keepLocal: false), context: ctx)
        XCTAssertEqual(only.summary, "Export search results as VOTABLE to storage (projects/m31)", "a path means storage")
        let payload = try JSONDecoder().decode(ExportSearchResultsTool.Payload.self, from: only.payload)
        XCTAssertTrue(payload.goesToStorage)
        XCTAssertEqual(payload.keepLocal, false)

        let old = try JSONDecoder().decode(ExportSearchResultsTool.Payload.self, from: Data(#"{"format":"csv"}"#.utf8))
        XCTAssertFalse(old.goesToStorage, "a proposal from before reads as Downloads only")

        do {
            _ = try await tool.plan(.init(format: "csv", keepLocal: false), context: ctx)
            XCTFail("kept nowhere")
        } catch ToolFailureReason.invalidArgument(let why) {
            XCTAssertTrue(why.contains("kept nowhere"), why)
        }
        do {
            _ = try await tool.plan(.init(format: "csv", uploadToVOSpace: false, vospacePath: "x"), context: ctx)
            XCTFail("a path without the upload")
        } catch ToolFailureReason.invalidArgument {}
    }

    func testTheAnswerSaysWhereItWentInStorage() async throws {
        let applier = ExportSearchResultsApplier(
            run: { request in
                XCTAssertEqual(request.vospacePath, "projects/m31")
                return SearchExport(path: nil, shape: SearchExport.shown(rows: 3, columns: 2), storagePath: "projects/m31/r.csv")
            },
            activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let payload = ExportSearchResultsTool.Payload(format: "csv", adql: nil, maxRecords: nil,
                                                      uploadToVOSpace: true, vospacePath: "projects/m31", keepLocal: false)
        let proposal = PendingProposal(toolName: "export_search_results", kind: "export_search_results", summary: "Export",
                                       payload: try JSONEncoder().encode(payload), origin: .external(clientID: "t"))
        let extra = try JSONDecoder().decode(AutoAppliedAck.Extra.self, from: try await applier.applyReturningResult(proposal))
        XCTAssertEqual(extra.file, "projects/m31/r.csv")
        XCTAssertTrue(extra.note?.hasSuffix("In storage at projects/m31/r.csv.") == true, extra.note ?? "")
    }
}
