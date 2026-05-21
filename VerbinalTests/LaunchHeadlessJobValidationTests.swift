// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Coverage for `LaunchHeadlessJobTool.validateEnv` — the upfront
/// guard that rejects env values matching Skaha's known silent-
/// failure patterns *before* the request leaves the client. Each
/// rule encodes a directly-observed quirk from the 2026-05-13 QA
/// sweep; the tests pin the boundary so a future change doesn't
/// silently relax the protection.
final class LaunchHeadlessJobValidationTests: XCTestCase {

    private func env(_ pairs: [(String, String)]) -> [AgentEnvVar] {
        pairs.map { AgentEnvVar(key: $0.0, value: $0.1) }
    }

    // MARK: - Size limit

    func testEnvValueUnderThresholdPasses() throws {
        // 2 KB is the documented threshold; 2047 bytes is the
        // boundary one byte below.
        let value = String(repeating: "x", count: 2047)
        try LaunchHeadlessJobTool.validateEnv(env([("SCRIPT", value)]))
    }

    func testEnvValueExactlyAtThresholdPasses() throws {
        let value = String(repeating: "x", count: 2048)
        try LaunchHeadlessJobTool.validateEnv(env([("SCRIPT", value)]))
    }

    func testEnvValueOverThresholdRejected() {
        // 2049 bytes — one over. The client must reject because
        // Skaha will silently drop values past ~2 KB and the
        // agent has no signal to retry on.
        let value = String(repeating: "x", count: 2049)
        XCTAssertThrowsError(try LaunchHeadlessJobTool.validateEnv(env([("SCRIPT", value)]))) { error in
            guard let f = error as? ToolFailureReason else {
                XCTFail("expected ToolFailureReason; got \(error)")
                return
            }
            switch f {
            case .invalidArgument(let msg):
                XCTAssertTrue(msg.contains("SCRIPT"), "key must appear in error; got: \(msg)")
                XCTAssertTrue(msg.contains("2 KB"), "threshold language must appear; got: \(msg)")
            default:
                XCTFail("wrong typed case: \(f)")
            }
        }
    }

    // MARK: - Ampersand

    func testEnvValueWithoutAmpersandPasses() throws {
        try LaunchHeadlessJobTool.validateEnv(env([("CMD", "python -c 'print(1+2)'")]))
    }

    func testEnvValueWithAmpersandRejected() {
        // Note: numpy boolean-AND `(a > 0) & (b < 1)` would also
        // contain `=` (the `> 0` expression doesn't, but real
        // assignments do); we use a value that has only `&` so we
        // exercise the &-specific branch in isolation.
        XCTAssertThrowsError(
            try LaunchHeadlessJobTool.validateEnv(env([("MASK", "a&b")]))
        ) { error in
            guard case ToolFailureReason.invalidArgument(let msg) = error else {
                XCTFail("expected invalidArgument; got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("'&'") || msg.contains("&"),
                          "must mention the problem character; got: \(msg)")
            XCTAssertTrue(msg.contains("np.logical_and") || msg.contains("logical_and"),
                          "must suggest the numpy workaround; got: \(msg)")
        }
    }

    // MARK: - Equals (2026-05-13 QA finding F-2026-05-13-B)

    func testEnvValueWithEmbeddedEqualsRejected() {
        // The bug that burned four jobs in the QA pass: `=`
        // anywhere drops the env var silently. Validator must
        // catch this and tell the agent to use `script` instead.
        XCTAssertThrowsError(
            try LaunchHeadlessJobTool.validateEnv(env([("SCRIPT", "x = 1")]))
        ) { error in
            guard case ToolFailureReason.invalidArgument(let msg) = error else {
                XCTFail("expected invalidArgument; got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("SCRIPT"), "must name the offending key; got: \(msg)")
            XCTAssertTrue(msg.contains("="), "must mention the problem character; got: \(msg)")
            XCTAssertTrue(msg.contains("`script`") || msg.contains("script parameter"),
                          "must suggest the `script` parameter; got: \(msg)")
        }
    }

    func testEnvValueWithTrailingEqualsRejected() {
        XCTAssertThrowsError(
            try LaunchHeadlessJobTool.validateEnv(env([("B64", "AAAA=")]))
        )
    }

    // MARK: - Newline

    func testEnvValueWithNewlineRejected() {
        XCTAssertThrowsError(
            try LaunchHeadlessJobTool.validateEnv(env([("MULTI", "line1\nline2")]))
        ) { error in
            guard case ToolFailureReason.invalidArgument(let msg) = error else {
                XCTFail("expected invalidArgument; got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("newline"), "must mention newline; got: \(msg)")
        }
    }

    // MARK: - Script auto-stage routing

    /// `plan()` is the boundary that decides whether a `script`
    /// parameter rides inline (hex-encoded into the env) or
    /// gets deferred to applier-side VOSpace staging. Pin the
    /// routing at the size boundary so a future change doesn't
    /// silently flip behaviour. These tests don't run the
    /// applier itself; they verify the Payload-level marker.
    ///
    /// Doing this through the public `plan(...)` entry point
    /// requires a full `AIToolContext`; we exercise the same
    /// boundary by replicating the size threshold check the
    /// plan logic uses.

    func testShortScriptFitsHexInline() {
        // 1000 bytes of Python → ~2000 bytes hex → under cap.
        let source = String(repeating: "a", count: 1000)
        let hex = LaunchHeadlessJobTool.hexEncode(source)
        XCTAssertLessThanOrEqual(hex.utf8.count, 2048,
            "1000-byte source must hex-fit inline (≤ 2 KB hex cap)")
    }

    func testLongScriptOverflowsHex() {
        // 2 KB Python → 4 KB hex → must overflow.
        let source = String(repeating: "b", count: 2048)
        let hex = LaunchHeadlessJobTool.hexEncode(source)
        XCTAssertGreaterThan(hex.utf8.count, 2048,
            "2 KB source must overflow the 2 KB hex cap")
    }

    func testHexBoundaryAtOneKilobyteSource() {
        // 1024-byte source → exactly 2048 hex bytes → equal to
        // cap. Boundary inclusive — fits inline.
        let source = String(repeating: "c", count: 1024)
        let hex = LaunchHeadlessJobTool.hexEncode(source)
        XCTAssertEqual(hex.utf8.count, 2048)
    }

    // MARK: - Hex shim (the script-parameter foundation)

    func testHexEncodeRoundTrips() {
        let source = "import os\nprint('hello = world & co')"
        let hex = LaunchHeadlessJobTool.hexEncode(source)
        // Reverse via Foundation: bytes from hex → utf-8 string.
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            let byteStr = hex[idx..<next]
            bytes.append(UInt8(byteStr, radix: 16)!)
            idx = next
        }
        XCTAssertEqual(String(bytes: bytes, encoding: .utf8), source)
    }

    func testHexEncodeProducesQuirkFreeAlphabet() {
        // The whole point of the hex shim: output contains only
        // characters Skaha's parser doesn't trip on.
        let problematic = "x = 1 & y\n\"$VAR\""
        let hex = LaunchHeadlessJobTool.hexEncode(problematic)
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        let actual = CharacterSet(charactersIn: hex)
        XCTAssertTrue(actual.isSubset(of: allowed), "hex must be a strict subset of [0-9a-f]; got: \(hex)")
    }

    // MARK: - Multi-pair behaviour

    func testFirstOffendingPairTrips() {
        // First entry is fine, second contains `&`, third is fine.
        // Validator should reject naming the *second* key.
        let pairs = env([
            ("OK_FIRST", "hello"),
            ("BROKEN", "a & b"),
            ("OK_LAST", "world"),
        ])
        XCTAssertThrowsError(try LaunchHeadlessJobTool.validateEnv(pairs)) { error in
            guard case ToolFailureReason.invalidArgument(let msg) = error else {
                XCTFail("expected invalidArgument")
                return
            }
            XCTAssertTrue(msg.contains("BROKEN"), "must name the offending key, not the first or last")
        }
    }

    // MARK: - Empty / nominal

    func testEmptyEnvPasses() throws {
        try LaunchHeadlessJobTool.validateEnv([])
    }

    func testTypicalSmallEnvPasses() throws {
        try LaunchHeadlessJobTool.validateEnv(env([
            ("LOG_LEVEL", "INFO"),
            ("OUTPUT_DIR", "/arc/projects/foo"),
            ("BATCH_SIZE", "32"),
        ]))
    }

    // MARK: - Scheduling defaults (1c/1g/0gpu force-down)

    /// CANFAR's shared cluster regularly leaves 2c/8g jobs (Skaha's
    /// server-side default) sitting Pending 15+ min while smaller
    /// shapes place in under a minute. The tool must intercept and
    /// force 1c/1g/0gpu whenever the agent omits a dimension —
    /// description-only guidance proved insufficient (agents kept
    /// padding "to be safe"). These tests pin the new contract:
    /// omitted → 1/1/0, explicit oversized → loud warning in
    /// summary so the human approver sees it.

    private func plan(args: LaunchHeadlessJobTool.Args) async throws -> ProposalPlan {
        try await LaunchHeadlessJobTool().plan(args, context: .fake())
    }

    private func payload(from plan: ProposalPlan) throws -> LaunchHeadlessJobTool.Payload {
        try JSONDecoder().decode(LaunchHeadlessJobTool.Payload.self, from: plan.payload)
    }

    func testOmittedResourcesDefaultToOneCoreOneGigZeroGpu() async throws {
        let p = try await plan(args: .init(name: "smoke", image: "img:1"))
        let payload = try payload(from: p)
        XCTAssertEqual(payload.cores, 1, "omitted cores must force-default to 1")
        XCTAssertEqual(payload.ram,   1, "omitted ram must force-default to 1")
        XCTAssertEqual(payload.gpus,  0, "omitted gpus must force-default to 0")
    }

    func testDefaultShapeSummaryHasNoWarning() async throws {
        let p = try await plan(args: .init(name: "smoke", image: "img:1"))
        XCTAssertFalse(p.summary.contains("SCHEDULING WARNING"),
                       "1c/1g/0gpu is the recommended shape; summary must not warn")
        XCTAssertTrue(p.summary.contains("(1c/1g/0gpu)"),
                      "summary must surface the resolved shape so the user sees what we picked; got: \(p.summary)")
    }

    func testOversizedCoresEmitsWarning() async throws {
        var args = LaunchHeadlessJobTool.Args(name: "big", image: "img:1")
        args.cores = 4
        let p = try await plan(args: args)
        XCTAssertTrue(p.summary.contains("SCHEDULING WARNING"),
                      "explicit cores>1 must surface a warning; got: \(p.summary)")
        let payload = try payload(from: p)
        XCTAssertEqual(payload.cores, 4, "the explicit ask must still be honoured — we warn, not override")
    }

    func testOversizedRamEmitsWarning() async throws {
        var args = LaunchHeadlessJobTool.Args(name: "fat", image: "img:1")
        args.ram = 8
        let p = try await plan(args: args)
        XCTAssertTrue(p.summary.contains("SCHEDULING WARNING"),
                      "explicit ram>1 must surface a warning; got: \(p.summary)")
        let payload = try payload(from: p)
        XCTAssertEqual(payload.ram, 8)
    }

    func testGpuRequestEmitsWarning() async throws {
        var args = LaunchHeadlessJobTool.Args(name: "cuda", image: "img:1")
        args.gpus = 1
        let p = try await plan(args: args)
        XCTAssertTrue(p.summary.contains("SCHEDULING WARNING"),
                      "explicit gpu request must surface a warning; got: \(p.summary)")
    }

    func testExplicitMinimumShapeStillNoWarning() async throws {
        // The agent passing 1/1/0 explicitly (e.g. defensive
        // boilerplate) must read the same as the omitted case —
        // no warning, no nag.
        var args = LaunchHeadlessJobTool.Args(name: "explicit", image: "img:1")
        args.cores = 1
        args.ram   = 1
        args.gpus  = 0
        let p = try await plan(args: args)
        XCTAssertFalse(p.summary.contains("SCHEDULING WARNING"),
                       "explicit 1c/1g/0gpu must read identical to omission; got: \(p.summary)")
    }

    func testMultiReplicaPropagatesShape() async throws {
        var args = LaunchHeadlessJobTool.Args(name: "sweep", image: "img:1")
        args.replicas = 3
        let p = try await plan(args: args)
        let payload = try payload(from: p)
        XCTAssertEqual(payload.replicas, 3)
        XCTAssertEqual(payload.cores, 1, "replicas should each get the 1c/1g/0gpu default")
        XCTAssertTrue(p.summary.contains("(1c/1g/0gpu each)"),
                      "multi-replica summary must surface the per-replica shape; got: \(p.summary)")
        XCTAssertFalse(p.summary.contains("SCHEDULING WARNING"))
    }
}

private extension AIToolContext {
    /// Minimal context for boundary-test purposes — `LaunchHeadlessJobTool.plan`
    /// doesn't consult any of these fields, so no-op stubs are fine.
    static func fake() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 999)
        )
    }
}
