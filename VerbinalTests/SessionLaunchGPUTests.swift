// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 41 step 3: an interactive session takes one GPU or none — the
/// launch form's Use a GPU, Settings' default, a relaunch and the tools —
/// and none at all when the platform offers none.
@MainActor
final class SessionLaunchGPUTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// What the form posted, by its fields; and the context the network
    /// answers, which a test can change.
    private final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var forms: [[String: String]] = []
        private var contextBody = #"{"cores": {"default": 1, "options": [1, 2]}, "memoryGB": {"default": 4, "options": [4, 8]}}"#
        func add(_ form: [String: String]) { lock.withLock { forms.append(form) } }
        var last: [String: String]? { lock.withLock { forms.last } }
        var context: String {
            get { lock.withLock { contextBody } }
            set { lock.withLock { contextBody = newValue } }
        }
    }

    /// The real form and service, over a network that answers the catalogue,
    /// the context and a session id, and keeps what was posted; the form
    /// offering `offer`.
    private func form(offer: GPUOffer, loaded: Bool = true) -> (SessionLaunchModel, Network) {
        let network = Network()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let body: String
            if url.hasSuffix("/v1/context") { body = network.context }
            else if url.hasSuffix("/v1/image") || url.hasSuffix("/v1/repository") { body = "[]" }
            else { network.add(Self.fields(request)); body = #"["sess-1"]"# }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = NetworkClient(session: MockURLProtocol.mockSession())
        let model = SessionLaunchModel(sessionService: SessionService(network: client), imageService: ImageService(network: client),
                                       recentLaunchStore: RecentLaunchStore())
        model.selectedImage = ImageParser.parse(RawImage(id: "images.canfar.net/skaha/notebook:1.0", types: ["notebook"]))
        model.sessionName = "gpu-test"
        if loaded {
            model.coreOptions = [1, 2, 4]
            model.ramOptions = [4, 8, 16]
        }
        model.gpuOffer = offer
        return (model, network)
    }

    private nonisolated static func fields(_ request: URLRequest) -> [String: String] {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
        }
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        return fields
    }

    private let staging = GPUOffer(counts: Array(1...7))

    // MARK: - The form

    /// Ticked in Flexible: the form becomes Fixed, and the launch asks for
    /// one GPU with resourceType=custom — the combination Skaha takes.
    func testTheCheckboxSendsOneGPU() async throws {
        let (model, posted) = form(offer: staging)
        XCTAssertEqual(model.resourceType, "flexible")
        model.usesAGPU = true
        XCTAssertEqual(model.resourceType, "fixed", "ticking it makes the resources Fixed")
        XCTAssertEqual(model.gpus, 1)
        await model.launch()
        let sent = try XCTUnwrap(posted.last)
        XCTAssertEqual(sent["gpus"], "1")
        XCTAssertEqual(sent["resourceType"], "custom")
    }

    func testNoTickSendsNoGPUs() async throws {
        let (model, posted) = form(offer: staging)
        model.resourceType = "fixed"
        await model.launch()
        XCTAssertNil(try XCTUnwrap(posted.last)["gpus"])
        model.usesAGPU = true
        model.usesAGPU = false
        XCTAssertEqual(model.resourceType, "fixed", "unticking leaves Fixed as it is")
        await model.launch()
        XCTAssertNil(try XCTUnwrap(posted.last)["gpus"])
    }

    func testNoOfferDisablesAndClearsTheTick() async throws {
        let (model, posted) = form(offer: staging)
        model.usesAGPU = true
        model.gpuOffer = .none
        XCTAssertFalse(model.usesAGPU, "a tick from before is cleared")
        model.usesAGPU = true
        XCTAssertFalse(model.usesAGPU, "it cannot be ticked")
        await model.launch()
        XCTAssertNil(try XCTUnwrap(posted.last)["gpus"])
    }

    /// The context refreshes: the offer arrives, and the checkbox works —
    /// through the form's own loading, as a refresh brings it.
    func testAnOfferArrivingEnablesTheCheckbox() async throws {
        let (model, network) = form(offer: .none, loaded: false)
        await model.loadImagesAndContext()
        XCTAssertEqual(model.gpuOffer, .none)
        model.usesAGPU = true
        XCTAssertFalse(model.usesAGPU)
        network.context = #"{"cores": {"default": 1, "options": [1, 2]}, "memoryGB": {"default": 4, "options": [4, 8]}, "gpus": {"options": [1, 2, 3, 4, 5, 6, 7]}}"#
        await model.loadImagesAndContext()
        XCTAssertEqual(model.gpuOffer, staging)
        model.usesAGPU = true
        XCTAssertTrue(model.usesAGPU)
    }

    /// Saved defaults of more than one GPU (a Settings picker had offered 7)
    /// start the form with one.
    func testASavedDefaultOfSeveralGPUsGivesOne() async throws {
        let (model, posted) = form(offer: staging)
        model.apply(LaunchResources(type: "fixed", cores: 2, ram: 8, gpus: nil))
        model.gpus = 7
        await model.launch()
        XCTAssertEqual(try XCTUnwrap(posted.last)["gpus"], "1", "an interactive session takes at most one")
    }

    // MARK: - A relaunch

    private func recorded(gpus: Int) -> RecentLaunch {
        RecentLaunch(name: "old", type: "notebook", image: "images.canfar.net/skaha/notebook:1.0",
                     resourceType: "fixed", cores: 2, ram: 8, gpus: gpus)
    }

    func testARecordedLaunchWithSeveralGPUsRelaunchesWithOne() async throws {
        let (model, posted) = form(offer: staging)
        let launched = await model.relaunch(recorded(gpus: 4))
        XCTAssertTrue(launched)
        XCTAssertEqual(try XCTUnwrap(posted.last)["gpus"], "1")
    }

    func testARecordedLaunchRelaunchesWithoutAGPUWhenNoneIsOffered() async throws {
        let (model, posted) = form(offer: .none)
        let launched = await model.relaunch(recorded(gpus: 1))
        XCTAssertTrue(launched)
        XCTAssertNil(try XCTUnwrap(posted.last)["gpus"])
        XCTAssertEqual(model.launchStatus, "Relaunched without a GPU: this platform offers none")
    }

    /// Before the context has loaded, a recorded GPU is not taken away.
    func testARecordedGPUIsKeptBeforeTheContextLoads() async throws {
        let (model, posted) = form(offer: .none, loaded: false)
        _ = await model.relaunch(recorded(gpus: 1))
        XCTAssertEqual(try XCTUnwrap(posted.last)["gpus"], "1")
    }

    // MARK: - show_launch_form's sizes

    func testTheFormRefusesMoreThanOneGPU() {
        let (model, _) = form(offer: staging)
        XCTAssertEqual(model.refusal(LaunchResources(gpus: 2)),
                       "an interactive session takes at most one GPU (gpus 0 or 1); batch jobs take more")
        XCTAssertNil(model.refusal(LaunchResources(gpus: 1)))
        XCTAssertNil(model.refusal(LaunchResources(gpus: 0)))
    }

    func testTheFormRefusesAGPUWhenNoneIsOffered() {
        let (model, _) = form(offer: .none)
        XCTAssertEqual(model.refusal(LaunchResources(gpus: 1)), "this platform offers no GPUs")
        let (unloaded, _) = form(offer: .none, loaded: false)
        XCTAssertNil(unloaded.refusal(LaunchResources(gpus: 1)), "not loaded yet: not judged")
    }

    // MARK: - launch_session

    private func plan(_ gpus: Int?, offer: GPUOffer?) async throws -> LaunchSessionTool.Payload {
        let tool = LaunchSessionTool(offer: { offer })
        let ctx = AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        let plan = try await tool.plan(.init(type: "notebook", name: "n", image: "images.canfar.net/skaha/notebook:1.0", gpus: gpus),
                                       context: ctx)
        return try JSONDecoder().decode(LaunchSessionTool.Payload.self, from: plan.payload)
    }

    func testLaunchSessionRefusesTwoGPUs() async {
        do {
            _ = try await plan(2, offer: staging)
            XCTFail("two GPUs for an interactive session")
        } catch let failure as ToolFailureReason {
            guard case .invalidArgument(let why) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(why, "An interactive session takes at most one GPU; batch jobs take more (launch_headless_job).")
        } catch { XCTFail("\(error)") }
    }

    func testLaunchSessionRefusesAGPUWhenNoneIsOffered() async {
        do {
            _ = try await plan(1, offer: GPUOffer.none)
            XCTFail("a GPU where none is offered")
        } catch let failure as ToolFailureReason {
            guard case .invalidArgument(let why) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(why, "This platform offers no GPUs.")
        } catch { XCTFail("\(error)") }
    }

    func testLaunchSessionSendsOneGPU() async throws {
        let one = try await plan(1, offer: staging), unknown = try await plan(1, offer: nil), none = try await plan(nil, offer: staging)
        XCTAssertEqual(one.gpus, 1)
        XCTAssertEqual(unknown.gpus, 1, "the context not known: Skaha judges")
        XCTAssertEqual(none.gpus, 0)
    }
}
