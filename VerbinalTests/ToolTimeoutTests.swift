// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Coverage for the read-tool watchdog primitive `withToolTimeout`
/// and its integration into `JSONReadTool.invoke`. Mirrors
/// `ApplierTimeoutTests` for the write-side primitive — both halves
/// of the MCP surface now have the same liveness guarantee, and we
/// want the same kind of contract pinned on both.
///
/// The QA report from 2026-05-15 named `list_headless_jobs` as
/// hanging "at least four times across the session, each time for
/// 4+ minutes" — the primitive below is the safety net that turns
/// those hangs into typed errors the agent can recognise and act
/// on.
final class ToolTimeoutTests: XCTestCase {

    // MARK: - Primitive contract

    /// Work that completes inside the deadline returns its value
    /// verbatim. The watchdog must never interfere with the happy
    /// path.
    func testFastWorkPassesThrough() async throws {
        let value = try await withToolTimeout(seconds: 5, label: "fast") {
            return "ok"
        }
        XCTAssertEqual(value, "ok")
    }

    /// Work that takes longer than the deadline throws a
    /// `ToolFailureReason.backendError` whose message names the
    /// tool label and the deadline. The MCP envelope
    /// (`JSONReadTool.invoke`) pattern-matches on this type to emit
    /// `isError: true` to the agent client.
    func testSlowWorkRaisesTypedTimeoutError() async {
        do {
            _ = try await withToolTimeout(seconds: 0.2, label: "list_headless_jobs") {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "never"
            }
            XCTFail("expected timeout to throw")
        } catch let f as ToolFailureReason {
            switch f {
            case .backendError(let msg):
                XCTAssertTrue(msg.contains("list_headless_jobs"),
                              "label must appear in the message; got: \(msg)")
                XCTAssertTrue(msg.contains("deadline"),
                              "deadline language must appear; got: \(msg)")
            default:
                XCTFail("wrong typed case: \(f)")
            }
        } catch {
            XCTFail("expected ToolFailureReason, got: \(error)")
        }
    }

    /// Errors thrown by the work closure pass through untouched.
    /// The watchdog adds a deadline; it does not rewrap business
    /// failures. Pins that callers' `catch let f as
    /// ToolFailureReason` arm still sees real tool errors.
    func testWorkErrorsPassThrough() async {
        struct CustomFailure: Error, Equatable { let code: Int }
        do {
            _ = try await withToolTimeout(seconds: 5, label: "passthrough") {
                throw CustomFailure(code: 17)
            }
            XCTFail("expected work error to throw")
        } catch let c as CustomFailure {
            XCTAssertEqual(c.code, 17)
        } catch {
            XCTFail("expected CustomFailure verbatim, got: \(error)")
        }
    }

    /// `ToolFailureReason` thrown by the work closure must pass
    /// through verbatim, not be wrapped in another "exceeded
    /// deadline" envelope. Tools that surface domain failures
    /// (`invalidArgument`, `unknownTarget`, etc.) need their case
    /// preserved.
    func testToolFailureReasonPassesThrough() async {
        do {
            _ = try await withToolTimeout(seconds: 5, label: "passthrough") {
                throw ToolFailureReason.invalidArgument("not a number")
            }
            XCTFail("expected ToolFailureReason to throw")
        } catch let f as ToolFailureReason {
            switch f {
            case .invalidArgument(let msg):
                XCTAssertEqual(msg, "not a number")
            default:
                XCTFail("watchdog rewrapped a domain failure; got: \(f)")
            }
        } catch {
            XCTFail("expected ToolFailureReason, got: \(error)")
        }
    }

    // MARK: - JSONReadTool.invoke integration

    /// A JSONReadTool whose `handle` sleeps longer than the
    /// per-tool deadline must surface a `failed(.backendError(…))`
    /// from `invoke(...)` — not a panic, not a stall, not a
    /// rewrapped success envelope. Tests the full envelope including
    /// the conversion from `ToolFailureReason` to `ToolResult`.
    func testJSONReadToolHangingHandleSurfacesAsFailed() async throws {
        struct HangingTool: JSONReadTool {
            typealias Args = EmptyArgs
            typealias Output = EmptyArgs
            let definition = AIToolDefinition.withStaticSchema(
                name: "hangs_forever",
                description: "test fixture: sleeps past its deadline",
                schema: #"{"type":"object","properties":{},"additionalProperties":false}"#
            )
            var toolTimeoutSeconds: TimeInterval { 0.2 }
            func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> EmptyArgs {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return EmptyArgs()
            }
        }
        let tool = HangingTool()
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 99)
        )
        let result = await tool.invoke(arguments: Data(), context: ctx)
        switch result {
        case .failed(let reason):
            guard case .backendError(let msg) = reason else {
                XCTFail("expected backendError reason; got: \(reason)")
                return
            }
            XCTAssertTrue(msg.contains("hangs_forever"),
                          "tool name must appear in the deadline message; got: \(msg)")
        case .data:
            XCTFail("hanging tool should not produce a data envelope")
        case .proposed:
            XCTFail("hanging read tool should not produce a proposal")
        }
    }

    /// A JSONReadTool with the default 60s deadline that returns
    /// fast must produce a data envelope — verifies the wrapper
    /// doesn't strangle the happy path through the protocol's
    /// default property.
    func testJSONReadToolFastHandleReturnsData() async throws {
        struct FastTool: JSONReadTool {
            typealias Args = EmptyArgs
            struct Output: Encodable, Sendable { let value: Int }
            let definition = AIToolDefinition.withStaticSchema(
                name: "fast_tool",
                description: "test fixture: returns immediately",
                schema: #"{"type":"object","properties":{},"additionalProperties":false}"#
            )
            func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
                return Output(value: 7)
            }
        }
        let tool = FastTool()
        let ctx = AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 99)
        )
        let result = await tool.invoke(arguments: Data(), context: ctx)
        switch result {
        case .data(let bytes):
            struct Decoded: Decodable { let value: Int }
            let decoded = try JSONDecoder().decode(Decoded.self, from: bytes)
            XCTAssertEqual(decoded.value, 7)
        case .failed(let f):
            XCTFail("expected data; got failed(\(f))")
        case .proposed:
            XCTFail("read tool should not surface a proposal")
        }
    }
}
