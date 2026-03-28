// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class SessionModelTests: XCTestCase {

    private func makeResponse(
        id: String = "sess-1",
        status: String = "Running",
        requestedRAM: String? = "8G",
        requestedCPUCores: String? = "4",
        requestedGPUCores: String? = "0",
        ramInUse: String? = "2G",
        cpuCoresInUse: String? = "1.5",
        isFixedResources: Bool? = true
    ) -> SkahaSessionResponse {
        SkahaSessionResponse(
            id: id,
            userid: "user1",
            runAsUID: "1000",
            runAsGID: "1000",
            supplementalGroups: [100],
            image: "images.canfar.net/skaha/notebook:latest",
            type: "notebook",
            status: status,
            name: "notebook1",
            startTime: "2026-03-25T10:00:00Z",
            expiryTime: "2026-04-25T10:00:00Z",
            connectURL: "https://ws-uv.canfar.net/session/sess-1",
            requestedRAM: requestedRAM,
            requestedCPUCores: requestedCPUCores,
            requestedGPUCores: requestedGPUCores,
            ramInUse: ramInUse,
            cpuCoresInUse: cpuCoresInUse,
            isFixedResources: isFixedResources
        )
    }

    func testInitFromSkahaResponse() {
        let session = Session(from: makeResponse())

        XCTAssertEqual(session.id, "sess-1")
        XCTAssertEqual(session.sessionType, "notebook")
        XCTAssertEqual(session.sessionName, "notebook1")
        XCTAssertEqual(session.status, "Running")
        XCTAssertEqual(session.containerImage, "images.canfar.net/skaha/notebook:latest")
        XCTAssertEqual(session.connectUrl, "https://ws-uv.canfar.net/session/sess-1")
        XCTAssertEqual(session.memoryAllocated, "8G")
        XCTAssertEqual(session.memoryUsage, "2G")
        XCTAssertEqual(session.cpuAllocated, "4")
        XCTAssertEqual(session.cpuUsage, "1.5")
        XCTAssertEqual(session.gpuAllocated, "0")
        XCTAssertTrue(session.isFixedResources)
    }

    func testInitFromSkahaResponseWithNilOptionals() {
        let session = Session(from: makeResponse(
            requestedRAM: nil,
            requestedCPUCores: nil,
            requestedGPUCores: nil,
            ramInUse: nil,
            cpuCoresInUse: nil,
            isFixedResources: nil
        ))

        XCTAssertEqual(session.memoryAllocated, "")
        XCTAssertEqual(session.memoryUsage, "")
        XCTAssertEqual(session.cpuAllocated, "")
        XCTAssertEqual(session.cpuUsage, "")
        XCTAssertEqual(session.gpuAllocated, "")
        XCTAssertTrue(session.isFixedResources) // defaults to true
    }

    func testIsPendingForPendingStatus() {
        let session = Session(from: makeResponse(status: "Pending"))
        XCTAssertTrue(session.isPending)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.isFailed)
    }

    func testIsPendingForTerminatingStatus() {
        let session = Session(from: makeResponse(status: "Terminating"))
        XCTAssertTrue(session.isPending)
    }

    func testIsRunning() {
        let session = Session(from: makeResponse(status: "Running"))
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(session.isPending)
        XCTAssertFalse(session.isFailed)
    }

    func testIsFailedForFailedStatus() {
        let session = Session(from: makeResponse(status: "Failed"))
        XCTAssertTrue(session.isFailed)
        XCTAssertFalse(session.isRunning)
    }

    func testIsFailedForErrorStatus() {
        let session = Session(from: makeResponse(status: "Error"))
        XCTAssertTrue(session.isFailed)
    }

    func testUnrecognizedStatusIsNeitherPendingNorRunningNorFailed() {
        let session = Session(from: makeResponse(status: "Succeeded"))
        XCTAssertFalse(session.isPending)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.isFailed)
    }

    // MARK: - Case Insensitive Status

    func testStatusChecksAreCaseInsensitive() {
        XCTAssertTrue(Session(from: makeResponse(status: "running")).isRunning)
        XCTAssertTrue(Session(from: makeResponse(status: "RUNNING")).isRunning)
        XCTAssertTrue(Session(from: makeResponse(status: "pending")).isPending)
        XCTAssertTrue(Session(from: makeResponse(status: "PENDING")).isPending)
        XCTAssertTrue(Session(from: makeResponse(status: "failed")).isFailed)
        XCTAssertTrue(Session(from: makeResponse(status: "error")).isFailed)
        XCTAssertTrue(Session(from: makeResponse(status: "terminating")).isPending)
    }
}
