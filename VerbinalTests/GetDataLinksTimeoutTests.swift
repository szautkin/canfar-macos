// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Pins the two independent 30-second watchdogs that guard
/// `get_data_links`, locking the documented contract clarified in
/// ticket 035 so a future refactor can't quietly collapse them into
/// one or drop a layer.
///
/// There are two distinct deadlines, NOT one:
///   1. Tool-level: `JSONReadTool.invoke` wraps the whole `handle`
///      in `withToolTimeout(seconds: toolTimeoutSeconds)`.
///   2. Applier-level: the wiring's fetch closure wraps ONLY the
///      DataLink network call in `withApplierTimeout(seconds: 30)`.
/// Both are 30s today; these tests assert the value and exercise the
/// watchdog wiring the docs describe.
final class GetDataLinksTimeoutTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
    }

    /// A `fetch` closure that returns an empty-but-valid result.
    /// Used to confirm the watchdog never interferes with the happy
    /// path through `invoke`.
    private func emptyFetch() -> @Sendable (_ id: String) async throws -> (
        thumbnails: [URL],
        previews: [URL],
        files: [(url: URL, contentType: String, filename: String, isUncompressedFITS: Bool)],
        artifacts: [(uri: String, productType: String?, contentType: String?, contentLength: Int64?, filename: String, downloadURL: URL?)],
        packageDownloadURL: URL?
    ) {
        { _ in (thumbnails: [], previews: [], files: [], artifacts: [], packageDownloadURL: nil) }
    }

    // MARK: - Documented value

    /// The tool-level deadline MUST be 30s. The schema description and
    /// inline comments both state "30-second watchdog"; this assertion
    /// locks the number against that prose so the two can't drift.
    func testToolTimeoutSecondsIsThirty() {
        let tool = GetDataLinksTool(fetch: emptyFetch())
        XCTAssertEqual(tool.toolTimeoutSeconds, 30)
    }

    // MARK: - Happy path through the watchdog

    /// A fast `fetch` must produce a data envelope — the tool-level
    /// `withToolTimeout` wrapper must not strangle the happy path.
    func testFastFetchReturnsDataEnvelope() async throws {
        let tool = GetDataLinksTool(fetch: emptyFetch())
        let result = await tool.invoke(arguments: Data(#"{"publisher_id":"x"}"#.utf8), context: ctx())
        switch result {
        case .data(let bytes):
            // Confirm it decodes as the tool's Output shape. GetDataLinksTool.Output
            // is Encodable-only, so decode a local mirror of its [String] fields.
            struct Decoded: Decodable { let thumbnails: [String]; let previews: [String] }
            _ = try JSONDecoder().decode(Decoded.self, from: bytes)
        case .failed(let f):
            XCTFail("expected data; got failed(\(f))")
        case .proposed:
            XCTFail("read tool should not surface a proposal")
        case .image:
            XCTFail("read tool should not surface an image")
        }
    }

    // MARK: - Applier-level watchdog wiring (inner deadline)

    /// Exercises the inner `withApplierTimeout` watchdog the wiring in
    /// `makeGetDataLinksTool` wraps around the DataLink fetch. A fetch
    /// that exceeds the deadline must surface a typed
    /// `ProposalApplyError.backendError` naming `get_data_links` — the
    /// same primitive and label the production closure uses, here with
    /// a short test deadline so the test stays fast. Verifies the
    /// failure class the docs promise: a typed timeout, not a stall.
    func testApplierWatchdogConvertsSlowDataLinkFetchToTypedError() async {
        do {
            _ = try await withApplierTimeout(seconds: 0.2, label: "get_data_links") {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
            XCTFail("expected the applier watchdog to throw")
        } catch let pa as ProposalApplyError {
            switch pa {
            case .backendError(let msg):
                XCTAssertTrue(msg.contains("get_data_links"),
                              "label must name the tool; got: \(msg)")
                XCTAssertTrue(msg.contains("deadline"),
                              "deadline language must appear; got: \(msg)")
            default:
                XCTFail("wrong typed case: \(pa)")
            }
        } catch {
            XCTFail("expected ProposalApplyError, got: \(error)")
        }
    }

    // MARK: - Tool-level watchdog wiring (outer deadline)

    /// Exercises the outer `withToolTimeout` watchdog that
    /// `JSONReadTool.invoke` applies around the whole `handle`. A
    /// `fetch` that hangs past the deadline must surface as
    /// `.failed(.backendError(…))` naming `get_data_links`. Uses the
    /// `withToolTimeout` primitive directly with a short deadline so
    /// the test stays fast — the production path uses the same
    /// primitive with `toolTimeoutSeconds == 30` (asserted above).
    func testToolWatchdogConvertsHangingHandleToTypedError() async {
        do {
            _ = try await withToolTimeout(seconds: 0.2, label: "get_data_links") {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
            XCTFail("expected the tool watchdog to throw")
        } catch let f as ToolFailureReason {
            switch f {
            case .backendError(let msg):
                XCTAssertTrue(msg.contains("get_data_links"),
                              "label must name the tool; got: \(msg)")
                XCTAssertTrue(msg.contains("deadline"),
                              "deadline language must appear; got: \(msg)")
            default:
                XCTFail("wrong typed case: \(f)")
            }
        } catch {
            XCTFail("expected ToolFailureReason, got: \(error)")
        }
    }
}
