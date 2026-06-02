// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
import VerbinalKit

/// Verifies that session/job log & event loaders surface a typed `Result`
/// (failure on fetch error, success pass-through) instead of swallowing
/// errors with `try?` and returning a nil/blank result.
@MainActor
final class SessionLogFetchTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeNetwork() -> NetworkClient {
        NetworkClient(session: MockURLProtocol.mockSession())
    }

    private func respondSuccess(_ body: String) {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
    }

    private func respondFailure(statusCode: Int) {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
    }

    // MARK: - SessionListModel

    func testGetSessionEventsSurfacesErrorOnFailure() async {
        let model = SessionListModel(sessionService: SessionService(network: makeNetwork()))
        respondFailure(statusCode: 401)

        let result = await model.getSessionEvents(id: "sess-1")

        guard case .failure(let error) = result else {
            XCTFail("Expected .failure, got \(result)")
            return
        }
        XCTAssertTrue(error is NetworkError)
    }

    func testGetSessionLogsSurfacesErrorOnFailure() async {
        let model = SessionListModel(sessionService: SessionService(network: makeNetwork()))
        respondFailure(statusCode: 500)

        let result = await model.getSessionLogs(id: "sess-1")

        guard case .failure = result else {
            XCTFail("Expected .failure, got \(result)")
            return
        }
    }

    func testGetSessionEventsPassesContentThroughOnSuccess() async {
        let model = SessionListModel(sessionService: SessionService(network: makeNetwork()))
        respondSuccess("event line A\nevent line B")

        let result = await model.getSessionEvents(id: "sess-1")

        guard case .success(let content) = result else {
            XCTFail("Expected .success, got \(result)")
            return
        }
        XCTAssertEqual(content, "event line A\nevent line B")
    }

    func testGetSessionLogsPassesContentThroughOnSuccess() async {
        let model = SessionListModel(sessionService: SessionService(network: makeNetwork()))
        respondSuccess("log content")

        let result = await model.getSessionLogs(id: "sess-1")

        guard case .success(let content) = result else {
            XCTFail("Expected .success, got \(result)")
            return
        }
        XCTAssertEqual(content, "log content")
    }

    // MARK: - HeadlessMonitorModel

    func testGetEventsSurfacesErrorOnFailure() async {
        let model = HeadlessMonitorModel(headlessService: HeadlessService(network: makeNetwork()))
        respondFailure(statusCode: 401)

        let result = await model.getEvents(id: "job-1")

        guard case .failure(let error) = result else {
            XCTFail("Expected .failure, got \(result)")
            return
        }
        XCTAssertTrue(error is NetworkError)
    }

    func testGetLogsSurfacesErrorOnFailure() async {
        let model = HeadlessMonitorModel(headlessService: HeadlessService(network: makeNetwork()))
        respondFailure(statusCode: 503)

        let result = await model.getLogs(id: "job-1")

        guard case .failure = result else {
            XCTFail("Expected .failure, got \(result)")
            return
        }
    }

    func testGetEventsPassesContentThroughOnSuccess() async {
        let model = HeadlessMonitorModel(headlessService: HeadlessService(network: makeNetwork()))
        respondSuccess("k8s event")

        let result = await model.getEvents(id: "job-1")

        guard case .success(let content) = result else {
            XCTFail("Expected .success, got \(result)")
            return
        }
        XCTAssertEqual(content, "k8s event")
    }

    func testGetLogsPassesContentThroughOnSuccess() async {
        let model = HeadlessMonitorModel(headlessService: HeadlessService(network: makeNetwork()))
        respondSuccess("container log output")

        let result = await model.getLogs(id: "job-1")

        guard case .success(let content) = result else {
            XCTFail("Expected .success, got \(result)")
            return
        }
        XCTAssertEqual(content, "container log output")
    }

    // MARK: - Display Mapping (distinguishes error vs empty-success)

    func testLogResultTextRendersErrorDistinctly() {
        let result: Result<String, Error> = .failure(NetworkError.unauthorized)
        let text = SessionDisplay.logResultText(result, emptyFallback: "No events available")

        XCTAssertNotEqual(text, "No events available")
        XCTAssertTrue(text.hasPrefix("Failed to load:"))
        XCTAssertTrue(text.contains(NetworkError.unauthorized.localizedDescription))
    }

    func testLogResultTextEmptySuccessFallsBack() {
        let result: Result<String, Error> = .success("   \n  ")
        let text = SessionDisplay.logResultText(result, emptyFallback: "No logs available")

        XCTAssertEqual(text, "No logs available")
    }

    func testLogResultTextSuccessPassesContentThrough() {
        let result: Result<String, Error> = .success("real content")
        let text = SessionDisplay.logResultText(result, emptyFallback: "No logs available")

        XCTAssertEqual(text, "real content")
    }
}
