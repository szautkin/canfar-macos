// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Coverage for the explicit AI-Remote-Compute lifecycle tools
/// (`start_compute` / `stop_compute`) layered on top of the lazy
/// `run_code`. Mirrors `RunCodeToolTests`: pure plan/clamp logic where
/// possible, plus an applier path exercised against a `SessionService`
/// stubbed over `MockURLProtocol` (no real network). The session-name
/// and reuse-decision literals are single-sourced in `RunCodeContract`.
final class ComputeLifecycleToolsTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    private func argsData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private let setImage: @Sendable () -> String = { "images.canfar.net/p/verbinal-compute:1.0" }

    // MARK: - RunCodeContract resource clamping (pure)

    func testClampCoresFloorAndCeiling() {
        XCTAssertEqual(RunCodeContract.clampCores(0), 1, "0 (shared pool) clamps up to the 1-core floor")
        XCTAssertEqual(RunCodeContract.clampCores(-5), 1)
        XCTAssertEqual(RunCodeContract.clampCores(4), 4)
        XCTAssertEqual(RunCodeContract.clampCores(9999), RunCodeContract.maxCores)
    }

    func testClampRamFloorAndCeiling() {
        XCTAssertEqual(RunCodeContract.clampRam(0), 1)
        XCTAssertEqual(RunCodeContract.clampRam(8), 8)
        XCTAssertEqual(RunCodeContract.clampRam(9999), RunCodeContract.maxRam)
    }

    // MARK: - start_compute (write / plan)

    func testStartDisabledWhenImageUnset() async {
        let tool = StartComputeTool(resolveImage: { "" }, resolveResources: { (2, 4) })
        let r = await tool.invoke(arguments: argsData([:]), context: ctx())
        guard case .failed(let reason) = r else { return XCTFail("expected .failed, got \(r)") }
        XCTAssertEqual(reason.auditTag, "invalidArgument")
    }

    func testStartUsesSettingsDefaultWhenNoArgs() async throws {
        // No cores/ram args → the Settings-resolved default is used.
        let tool = StartComputeTool(resolveImage: setImage, resolveResources: { (4, 16) })
        let r = await tool.invoke(arguments: argsData([:]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed, got \(r)") }
        XCTAssertEqual(p.kind, "start_compute")
        let payload = try JSONDecoder().decode(StartComputeTool.Payload.self, from: p.payload)
        XCTAssertEqual(payload.cores, 4)
        XCTAssertEqual(payload.ram, 16)
        XCTAssertEqual(payload.image, "images.canfar.net/p/verbinal-compute:1.0")
    }

    func testStartArgsOverrideSettingsDefault() async throws {
        // Agent-supplied size wins over the configured default.
        let tool = StartComputeTool(resolveImage: setImage, resolveResources: { (1, 1) })
        let r = await tool.invoke(arguments: argsData(["cores": 8, "ram": 32]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed") }
        let payload = try JSONDecoder().decode(StartComputeTool.Payload.self, from: p.payload)
        XCTAssertEqual(payload.cores, 8)
        XCTAssertEqual(payload.ram, 32)
    }

    func testStartClampsOutOfRangeArgs() async throws {
        let tool = StartComputeTool(resolveImage: setImage, resolveResources: { (1, 1) })
        let r = await tool.invoke(arguments: argsData(["cores": 9999, "ram": 0]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed") }
        let payload = try JSONDecoder().decode(StartComputeTool.Payload.self, from: p.payload)
        XCTAssertEqual(payload.cores, RunCodeContract.maxCores, "over-cap cores clamp to the ceiling")
        XCTAssertEqual(payload.ram, 1, "0 GB clamps up to the 1-GB floor")
    }

    func testStartSummarySurfacesSize() async throws {
        let tool = StartComputeTool(resolveImage: setImage, resolveResources: { (2, 8) })
        let r = await tool.invoke(arguments: argsData([:]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed") }
        XCTAssertTrue(p.summary.contains("2 cores"))
        XCTAssertTrue(p.summary.contains("8 GB"))
        XCTAssertTrue(p.summary.contains(RunCodeContract.sessionName))
    }

    // MARK: - stop_compute (write / plan)

    func testStopProducesEmptyPayloadProposal() async throws {
        let tool = StopComputeTool()
        let r = await tool.invoke(arguments: argsData([:]), context: ctx())
        guard case .proposed(let p) = r else { return XCTFail("expected .proposed, got \(r)") }
        XCTAssertEqual(p.kind, "stop_compute")
        XCTAssertTrue(p.summary.contains(RunCodeContract.sessionName))
        // Empty-object payload decodes cleanly.
        _ = try JSONDecoder().decode(StopComputeTool.Payload.self, from: p.payload)
    }

    // MARK: - stop_compute applier (over a stubbed SessionService)

    /// One session JSON object as Skaha returns it. Only the fields
    /// `Session(from:)` requires are populated.
    private func sessionJSON(id: String, type: String, name: String, status: String) -> String {
        """
        {"id":"\(id)","image":"images.canfar.net/p/verbinal-compute:1.0",
         "type":"\(type)","status":"\(status)","name":"\(name)",
         "startTime":"2026-06-05T00:00:00Z","expiryTime":"2026-06-05T08:00:00Z",
         "connectURL":"https://example.invalid/\(id)"}
        """
    }

    private func makeService() -> SessionService {
        SessionService(network: NetworkClient(session: MockURLProtocol.mockSession()))
    }

    private func makeProposal(kind: String) -> PendingProposal {
        PendingProposal(
            toolName: kind, kind: kind, summary: "test",
            payload: try! JSONEncoder().encode(StopComputeTool.Payload()),
            origin: .external(clientID: "test"))
    }

    @MainActor
    func testStopNoOpsWhenNoMatchingSession() async throws {
        let service = makeService()
        let activity = AgentActivityStore(fileName: "test_stop_noop_\(UUID().uuidString).json")
        let deleteHit = LockedBox(false)
        // getSessions returns only a NON-matching session → no delete.
        MockURLProtocol.requestHandler = { request in
            let method = request.httpMethod ?? "GET"
            if method == "DELETE" { deleteHit.set(true) }
            let body = "[\(self.sessionJSON(id: "other", type: "notebook", name: "mynb", status: "running"))]"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let applier = StopComputeApplier(service: service, activity: activity)
        try await applier.apply(makeProposal(kind: "stop_compute"))
        XCTAssertFalse(deleteHit.get(), "no matching compute instance → must not call deleteSession")
    }

    @MainActor
    func testStopDeletesWhenRunningInstanceExists() async throws {
        let service = makeService()
        let activity = AgentActivityStore(fileName: "test_stop_del_\(UUID().uuidString).json")
        let deletedID = LockedBox<String?>(nil)
        MockURLProtocol.requestHandler = { request in
            let method = request.httpMethod ?? "GET"
            if method == "DELETE" {
                // Last path component is the session id Skaha deletes.
                deletedID.set(request.url?.lastPathComponent)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }
            let body = "[\(self.sessionJSON(id: "vc-1", type: RunCodeContract.sessionType, name: RunCodeContract.sessionName, status: "running"))]"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let applier = StopComputeApplier(service: service, activity: activity)
        try await applier.apply(makeProposal(kind: "stop_compute"))
        XCTAssertEqual(deletedID.get(), "vc-1", "a running verbinal-compute instance must be deleted by id")
    }

    @MainActor
    func testStopDeletesWhenPendingInstanceExists() async throws {
        // `pending` (still provisioning) counts as a matching instance.
        let service = makeService()
        let activity = AgentActivityStore(fileName: "test_stop_pend_\(UUID().uuidString).json")
        let deletedID = LockedBox<String?>(nil)
        MockURLProtocol.requestHandler = { request in
            if (request.httpMethod ?? "GET") == "DELETE" {
                deletedID.set(request.url?.lastPathComponent)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }
            let body = "[\(self.sessionJSON(id: "vc-2", type: RunCodeContract.sessionType, name: RunCodeContract.sessionName, status: "pending"))]"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let applier = StopComputeApplier(service: service, activity: activity)
        try await applier.apply(makeProposal(kind: "stop_compute"))
        XCTAssertEqual(deletedID.get(), "vc-2")
    }
}

/// Tiny thread-safe box so the `MockURLProtocol` handler (a `@Sendable`
/// closure run on URLSession's queue) can record what the applier did
/// without tripping strict-concurrency capture rules.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
