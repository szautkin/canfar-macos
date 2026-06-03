// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Unit coverage for the `run_code` / `run_code_output` pair and the
/// shared file-drop contract. The contract here MUST stay in lockstep
/// with the verbinal-compute watcher image
/// (`dev_info/verbinal-compute-image-spec.md`); these tests pin the
/// client side of it. No network — stubbed closures only.
final class RunCodeToolTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    private func argsData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private let setImage: @Sendable () -> String = { "images.canfar.net/p/verbinal-compute:1.0" }

    // MARK: - run_code (write / plan)

    func testDisabledWhenImageUnset() async {
        let tool = RunCodeTool(resolveImage: { "" })
        let r = await tool.invoke(arguments: argsData(["code": "print(1)"]), context: ctx())
        guard case .failed(let reason) = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertEqual(reason.auditTag, "invalidArgument")
    }

    func testEmptyCodeRejected() async {
        let tool = RunCodeTool(resolveImage: setImage)
        let r = await tool.invoke(arguments: argsData(["code": "   "]), context: ctx())
        guard case .failed(let reason) = r else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "invalidArgument")
    }

    func testUnsupportedLanguageRejected() async {
        let tool = RunCodeTool(resolveImage: setImage)
        let r = await tool.invoke(arguments: argsData(["code": "puts 1", "language": "ruby"]), context: ctx())
        guard case .failed(let reason) = r else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "invalidArgument")
    }

    func testProposalCarriesPayloadAndExecutionID() async throws {
        let tool = RunCodeTool(resolveImage: setImage)
        let r = await tool.invoke(arguments: argsData(["code": "print(2+2)", "language": "python"]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed, got \(r)") }
        XCTAssertEqual(p.kind, "run_code")
        let payload = try JSONDecoder().decode(RunCodeTool.Payload.self, from: p.payload)
        XCTAssertFalse(payload.id.isEmpty)
        XCTAssertEqual(payload.language, "python")
        XCTAssertEqual(payload.code, "print(2+2)")
        XCTAssertEqual(payload.timeout_seconds, 60, "default timeout")
        XCTAssertEqual(payload.image, "images.canfar.net/p/verbinal-compute:1.0")
        // The agent recovers the id to poll from the summary.
        XCTAssertTrue(p.summary.contains(payload.id),
                      "summary must surface execution_id so the agent can poll run_code_output")
    }

    func testTimeoutClampedToCeiling() async throws {
        let tool = RunCodeTool(resolveImage: setImage)
        let r = await tool.invoke(arguments: argsData(["code": "x=1", "timeout_seconds": 99999]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed") }
        let payload = try JSONDecoder().decode(RunCodeTool.Payload.self, from: p.payload)
        XCTAssertEqual(payload.timeout_seconds, RunCodeContract.maxTimeoutSeconds)
    }

    func testBashAccepted() async throws {
        let tool = RunCodeTool(resolveImage: setImage)
        let r = await tool.invoke(arguments: argsData(["code": "echo hi", "language": "bash"]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed") }
        let payload = try JSONDecoder().decode(RunCodeTool.Payload.self, from: p.payload)
        XCTAssertEqual(payload.language, "bash")
    }

    // MARK: - run_code_output (read / poll)

    private func outputTool(_ fetch: @escaping @Sendable (_ path: String, _ maxBytes: Int) async throws -> Data?) -> RunCodeOutputTool {
        RunCodeOutputTool(fetchOut: fetch)
    }

    private func decode(_ result: ToolResult) throws -> [String: Any] {
        guard case .data(let bytes) = result else {
            throw XCTSkip("expected .data, got \(result)")
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func testOutputEmptyIDRejected() async {
        let tool = outputTool { _, _ in nil }
        let r = await tool.invoke(arguments: argsData(["execution_id": "  "]), context: ctx())
        guard case .failed(let reason) = r else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "invalidArgument")
    }

    func testOutputNotReadyWhenAbsent() async throws {
        let tool = outputTool { _, _ in nil }   // 404 → nil
        let r = await tool.invoke(arguments: argsData(["execution_id": "abc"]), context: ctx())
        let obj = try decode(r)
        XCTAssertEqual(obj["ready"] as? Bool, false)
        XCTAssertEqual(obj["execution_id"] as? String, "abc")
        XCTAssertNotNil(obj["note"])
    }

    func testOutputReadyWithResult() async throws {
        let resultJSON = """
        {"id":"abc","status":"ok","exit_code":0,"stdout":"4\\n","stderr":"",
         "duration_ms":12,"truncated":false,
         "started_at":"2026-06-02T14:00:00Z","finished_at":"2026-06-02T14:00:00Z"}
        """
        let tool = outputTool { path, _ in
            XCTAssertEqual(path, RunCodeContract.outPath(id: "abc"))
            return Data(resultJSON.utf8)
        }
        let r = await tool.invoke(arguments: argsData(["execution_id": "abc"]), context: ctx())
        let obj = try decode(r)
        XCTAssertEqual(obj["ready"] as? Bool, true)
        XCTAssertEqual(obj["status"] as? String, "ok")
        XCTAssertEqual(obj["exit_code"] as? Int, 0)
        XCTAssertEqual(obj["stdout"] as? String, "4\n")
    }

    func testOutputBase64EncodingPassedThrough() async throws {
        // Binary stdout the watcher base64-encoded — the client must
        // surface the encoding so the agent decodes it.
        let resultJSON = """
        {"id":"bin","status":"ok","exit_code":0,"stdout":"AAEC","stdout_encoding":"base64"}
        """
        let tool = outputTool { _, _ in Data(resultJSON.utf8) }
        let r = await tool.invoke(arguments: argsData(["execution_id": "bin"]), context: ctx())
        let obj = try decode(r)
        XCTAssertEqual(obj["ready"] as? Bool, true)
        XCTAssertEqual(obj["stdout"] as? String, "AAEC")
        XCTAssertEqual(obj["stdout_encoding"] as? String, "base64")
    }

    func testOutputUnparseableTreatedAsNotReady() async throws {
        let tool = outputTool { _, _ in Data("{ partial".utf8) }   // mid-write / propagating
        let r = await tool.invoke(arguments: argsData(["execution_id": "abc"]), context: ctx())
        let obj = try decode(r)
        XCTAssertEqual(obj["ready"] as? Bool, false)
    }

    func testOutputAuthRequiredPropagates() async {
        let tool = outputTool { _, _ in throw ToolFailureReason.authRequired }
        let r = await tool.invoke(arguments: argsData(["execution_id": "abc"]), context: ctx())
        guard case .failed(let reason) = r else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason.auditTag, "authRequired")
    }

    // MARK: - Contract helpers

    func testSanitizeReplacesTheNineChars() {
        XCTAssertEqual(RunCodeContract.sanitize(#"a/b:c\d?e*f<g>h|i"j"#), "a_b_c_d_e_f_g_h_i_j")
        XCTAssertEqual(RunCodeContract.sanitize("plain-id_1.2"), "plain-id_1.2")
    }

    func testInboxAndOutPaths() {
        XCTAssertEqual(RunCodeContract.inboxPath(id: "x"), ".verbinal/exec/inbox/x.json")
        XCTAssertEqual(RunCodeContract.outPath(id: "a/b"), ".verbinal/exec/out/a_b.json")
    }

    func testReusableSessionMatchesRunningOrPendingContributedByName() {
        let name = RunCodeContract.sessionName
        let sessions = [
            RunCodeContract.SessionInfo(id: "s1", type: "notebook", name: name, status: "running"),        // wrong type
            RunCodeContract.SessionInfo(id: "s2", type: "contributed", name: "other", status: "running"),  // wrong name
            RunCodeContract.SessionInfo(id: "s3", type: "contributed", name: name, status: "terminating"), // terminating → skip
            RunCodeContract.SessionInfo(id: "s4", type: "contributed", name: name, status: "pending"),     // ✓ provisioning counts
        ]
        XCTAssertEqual(RunCodeContract.reusableSessionID(in: sessions, name: name), "s4",
                       "a pending compute session must count, so rapid cold-start calls don't spawn duplicates")
    }

    func testReusableSessionMatchesRunning() {
        let name = RunCodeContract.sessionName
        let sessions = [RunCodeContract.SessionInfo(id: "r", type: "contributed", name: name, status: "running")]
        XCTAssertEqual(RunCodeContract.reusableSessionID(in: sessions, name: name), "r")
    }

    func testReusableSessionNilWhenNoneUsable() {
        let name = RunCodeContract.sessionName
        let sessions = [
            RunCodeContract.SessionInfo(id: "s1", type: "contributed", name: name, status: "terminating"),
            RunCodeContract.SessionInfo(id: "s2", type: "contributed", name: name, status: "failed"),
        ]
        XCTAssertNil(RunCodeContract.reusableSessionID(in: sessions, name: name))
    }
}
