// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import XCTest
@testable import VerbinalKit

/// Plan 23 L1: every request recorded, classified once, named by service,
/// with nothing of its URL's path, query, headers or body kept.
final class RequestLedgerTests: XCTestCase {

    private func request(_ url: String, timeout: TimeInterval = 120) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = timeout
        return request
    }

    private func answer(_ status: Int) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    private func failing(_ error: Error) -> (URLRequest) async throws -> (Data, URLResponse) {
        { _ in throw error }
    }

    // MARK: - How a request ended

    func testTheClassification() {
        XCTAssertEqual(RequestOutcome(status: 200), .ok)
        XCTAssertEqual(RequestOutcome(status: 304), .ok)
        XCTAssertEqual(RequestOutcome(status: 401), .signInNeeded)
        XCTAssertEqual(RequestOutcome(status: 403), .notAllowed)
        XCTAssertEqual(RequestOutcome(status: 404), .notFound)
        XCTAssertEqual(RequestOutcome(status: 408), .timedOut)
        XCTAssertEqual(RequestOutcome(status: 429), .busy)
        XCTAssertEqual(RequestOutcome(status: 503), .busy)
        XCTAssertEqual(RequestOutcome(status: 400), .rejected)
        XCTAssertEqual(RequestOutcome(status: 500), .serverError)
        XCTAssertEqual(RequestOutcome(error: URLError(.timedOut)), .timedOut)
        XCTAssertEqual(RequestOutcome(error: URLError(.cannotFindHost)), .unreachable)
        XCTAssertEqual(RequestOutcome(error: URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(RequestOutcome(error: URLError(.secureConnectionFailed)), .unreachable)
        XCTAssertEqual(RequestOutcome(error: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(RequestOutcome(error: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(RequestOutcome(error: CancellationError()), .cancelled)
        XCTAssertEqual(RequestOutcome(error: NetworkError.unauthorized), .signInNeeded)
        XCTAssertEqual(RequestOutcome(error: NetworkError.httpError(502, "")), .serverError)
    }

    func testEachOutcomeSaysWhatItMeansAndWhetherToRetry() {
        for outcome in RequestOutcome.allCases {
            XCTAssertFalse(outcome.meaning.isEmpty, "\(outcome)")
            XCTAssertEqual(outcome.retry == nil, outcome == .ok, "\(outcome)")
        }
        XCTAssertEqual(RequestOutcome.timedOut.retry, .later)
        XCTAssertEqual(RequestOutcome.signInNeeded.retry, .afterSignIn)
        XCTAssertEqual(RequestOutcome.rejected.retry, .no)
        XCTAssertTrue(RequestOutcome.serverError.isServiceTrouble)
        XCTAssertFalse(RequestOutcome.signInNeeded.isServiceTrouble)
        XCTAssertFalse(RequestOutcome.offline.isServiceTrouble, "this Mac's network is not the service's fault")
    }

    // MARK: - Which service

    func testEveryEndpointInUseIsNamed() {
        let endpoints = APIEndpoints()
        let expected: [(String, String)] = [
            (endpoints.loginURL, "cadc-auth"),
            (endpoints.whoAmIURL, "cadc-auth"),
            (endpoints.userURL("someone"), "cadc-auth"),
            (endpoints.resourceCapsURL, "cadc-registry"),
            (endpoints.sessionsURL, "skaha"),
            (endpoints.imagesURL, "skaha"),
            (endpoints.storageURL("someone"), "vospace"),
            (endpoints.tapSyncURL, "cadc-tap"),
            (endpoints.caom2MetaURL, "cadc-caom2"),
            (endpoints.datalinkURL, "cadc-datalink"),
            (endpoints.caom2PkgURL, "cadc-data"),
            (endpoints.targetResolverURL, "cadc-resolver"),
            (endpoints.dataPubURL(forArtifactURI: "cadc:CFHT/1234o.fits")!.absoluteString, "cadc-data"),
        ]
        for (url, id) in expected {
            let service = RequestService.of(URL(string: url))
            XCTAssertEqual(service.id, id, url)
            XCTAssertNotEqual(service.name, service.host, "\(url) is named in words")
        }
    }

    func testAHostIsNamedWhenRegisteredAndByItselfOtherwise() {
        RequestService.register(host: "Mirror.Example", id: "vizier-example", name: "the VizieR mirror mirror.example")
        XCTAssertEqual(RequestService.of(URL(string: "https://mirror.example/TAPVizieR/tap/sync")).id, "vizier-example")
        XCTAssertEqual(RequestService.of(URL(string: "https://images.canfar.net/api/v2.0/projects")).id, "harbor")
        let unknown = RequestService.of(URL(string: "https://elsewhere.example/a/b"))
        XCTAssertEqual(unknown.id, "elsewhere.example")
        XCTAssertEqual(unknown.name, "elsewhere.example")
    }

    // MARK: - Recording

    func testAnAnswerIsRecordedWithItsServiceTimeAndStatus() async throws {
        let ledger = RequestLedger()
        _ = try await ledger.send(request("https://ws-uv.canfar.net/skaha/v1/session", timeout: 180), answer(200))
        let record = try XCTUnwrap(ledger.recent().last)
        XCTAssertEqual(record.service.id, "skaha")
        XCTAssertEqual(record.outcome, .ok)
        XCTAssertEqual(record.status, 200)
        XCTAssertEqual(record.timeout, 180)
        XCTAssertEqual(record.startedBy, .person)
        XCTAssertTrue(record.isFinished)
        XCTAssertTrue(ledger.waiting().isEmpty)
    }

    func testAFailureIsRecordedAndStillThrown() async {
        let ledger = RequestLedger()
        do {
            _ = try await ledger.send(request("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync"), failing(URLError(.timedOut)))
            XCTFail("the error goes on to the caller")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let record = ledger.recent().last
        XCTAssertEqual(record?.outcome, .timedOut)
        XCTAssertEqual(record?.code, "URLError -1001")
    }

    func testAnUnauthorizedAnswerIsSignInNeeded() async throws {
        let ledger = RequestLedger()
        _ = try await ledger.send(request("https://ws-cadc.canfar.net/ac/whoami"), answer(401))
        XCTAssertEqual(ledger.recent().last?.outcome, .signInNeeded)
        XCTAssertEqual(ledger.recent().last?.code, "HTTP 401")
    }

    func testACancelledRequestIsRecordedAsCancelled() async {
        let ledger = RequestLedger()
        let sent = Task {
            try await ledger.send(self.request("https://ws-uv.canfar.net/skaha/v1/session")) { _ -> (Data, URLResponse) in
                try await Task.sleep(for: .seconds(30))
                throw URLError(.timedOut)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ledger.waiting().count, 1, "waiting while in flight")
        sent.cancel()
        _ = await sent.result
        XCTAssertEqual(ledger.recent().last?.outcome, .cancelled)
    }

    func testWhoAskedIsKept() async throws {
        let ledger = RequestLedger()
        _ = try await Initiator.$current.withValue(.assistant) {
            try await ledger.send(request("https://ws-uv.canfar.net/skaha/v1/session"), answer(200))
        }
        XCTAssertEqual(ledger.recent().last?.startedBy, .assistant)
    }

    /// Nothing of a login — its path, its query, its form — is kept.
    func testALoginLeavesNothingOfItsFormOrPath() async throws {
        let ledger = RequestLedger()
        var login = request("https://ws-cadc.canfar.net/ac/login?next=%2Fsecret-place")
        login.httpMethod = "POST"
        login.httpBody = Data("username=someone&password=hunter2-secret".utf8)
        login.setValue("Bearer token-secret", forHTTPHeaderField: "Authorization")
        _ = try await ledger.send(login, answer(200))
        let json = try String(decoding: JSONEncoder().encode(ledger.recent()), as: UTF8.self)
        for leak in ["hunter2", "password", "token-secret", "Bearer", "secret-place", "/ac/login", "POST"] {
            XCTAssertFalse(json.contains(leak), "\(leak) reached the ledger: \(json)")
        }
        XCTAssertTrue(json.contains("CADC sign-in"))
    }

    func testOnlyTheLastFewHundredAreKept() async throws {
        let ledger = RequestLedger(keep: 3)
        for _ in 0..<5 { _ = try await ledger.send(request("https://ws-uv.canfar.net/skaha/v1/session"), answer(200)) }
        XCTAssertEqual(ledger.recent().count, 3)
    }

    // MARK: - Traces

    func testTracesNestAndARequestReachesEveryTraceAbove() async throws {
        let ledger = RequestLedger()
        let call = RequestTrace()
        let task = try await call.run { () -> RequestTrace in
            let task = RequestTrace()
            try await task.run {
                // A child task inherits the trace.
                try await Task {
                    _ = try await ledger.send(self.request("https://ws-uv.canfar.net/skaha/v1/session"), self.answer(200))
                }.value
            }
            _ = try await ledger.send(self.request("https://ws-cadc.canfar.net/ac/whoami"), self.answer(200))
            return task
        }
        XCTAssertEqual(task.records.map(\.service.id), ["skaha"])
        XCTAssertEqual(call.records.map(\.service.id), ["skaha", "cadc-auth"])
        XCTAssertTrue(call.waiting.isEmpty)
        XCTAssertNil(RequestTrace.current, "no trace outside run")
    }

    func testATraceSeesARequestWhileItWaits() async throws {
        let ledger = RequestLedger()
        let trace = RequestTrace()
        let sent = Task {
            try await trace.run {
                try await ledger.send(self.request("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync")) { request in
                    try await Task.sleep(for: .milliseconds(200))
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(trace.waiting.map(\.service.id), ["cadc-tap"])
        _ = try await sent.value
        XCTAssertTrue(trace.waiting.isEmpty)
        XCTAssertEqual(trace.records.first?.outcome, .ok)
    }

    // MARK: - A service failing and recovering

    func testThreeServiceFailuresInARowMarkItFailingAndAnAnswerRecovers() async throws {
        let ledger = RequestLedger()
        let events = EventBox()
        ledger.observe { event in
            switch event {
            case .serviceFailing(let service, _): events.add("failing \(service.id)")
            case .serviceRecovered(let service, _): events.add("recovered \(service.id)")
            default: break
            }
        }
        let tap = request("https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/sync")
        _ = try? await ledger.send(tap, failing(URLError(.timedOut)))
        _ = try await ledger.send(tap, answer(401))  // not the service's fault: neither counts nor clears
        _ = try? await ledger.send(tap, failing(URLError(.cannotConnectToHost)))
        XCTAssertFalse(ledger.isFailing("cadc-tap"))
        _ = try await ledger.send(tap, answer(503))
        XCTAssertTrue(ledger.isFailing("cadc-tap"))
        XCTAssertEqual(ledger.failingServices().map(\.id), ["cadc-tap"])
        _ = try? await ledger.send(tap, failing(URLError(.timedOut)))
        _ = try await ledger.send(tap, answer(200))
        XCTAssertFalse(ledger.isFailing("cadc-tap"))
        XCTAssertEqual(events.values, ["failing cadc-tap", "recovered cadc-tap"], "each said once")
    }

    func testStatsSayWhatTheTrafficShowed() async throws {
        let ledger = RequestLedger()
        let skaha = request("https://ws-uv.canfar.net/skaha/v1/session")
        _ = try await ledger.send(skaha, answer(200))
        _ = try await ledger.send(skaha, answer(500))
        let stats = try XCTUnwrap(ledger.stats().first { $0.service.id == "skaha" })
        XCTAssertEqual(stats.calls, 2)
        XCTAssertEqual(stats.failures, 1)
        XCTAssertEqual(stats.lastFailure?.status, 500)
        XCTAssertNotNil(stats.lastAnswer)
        XCTAssertNotNil(stats.medianSeconds)
        XCTAssertFalse(stats.isFailing)
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ value: String) { lock.withLock { list.append(value) } }
        var values: [String] { lock.withLock { list } }
    }
}
