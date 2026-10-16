// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 41 step 4: a batch job takes as many GPUs as the platform offers —
/// 0, or one of the context's options — in the form and from an assistant.
@MainActor
final class HeadlessGPUTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private let staging = GPUOffer(options: Array(1...7))
    private let gapped = GPUOffer(options: [1, 2, 4])

    // MARK: - The stepper

    func testTheStepperRunsThroughTheOptions() {
        XCTAssertEqual(staging.step(from: 0, up: true), 1)
        XCTAssertEqual(staging.step(from: 6, up: true), 7)
        XCTAssertEqual(staging.step(from: 7, up: true), 7, "no further than offered")
        XCTAssertEqual(staging.step(from: 1, up: false), 0)
        XCTAssertEqual(staging.step(from: 0, up: false), 0)
        XCTAssertEqual(gapped.step(from: 2, up: true), 4, "a gap is stepped over")
        XCTAssertEqual(gapped.step(from: 4, up: false), 2)
        XCTAssertEqual(GPUOffer.none.step(from: 0, up: true), 0)
    }

    func testTheOfferSaysWhatItOffers() {
        XCTAssertEqual(staging.described, "1–7")
        XCTAssertEqual(gapped.described, "1, 2, 4")
        XCTAssertEqual(GPUOffer(options: [2]).described, "2")
    }

    // MARK: - The form

    private final class Posted: @unchecked Sendable {
        private let lock = NSLock()
        private var body = ""
        var last: String { get { lock.withLock { body } } set { lock.withLock { body = newValue } } }
    }

    private func model() -> (HeadlessLaunchModel, Posted) {
        let posted = Posted()
        MockURLProtocol.requestHandler = { request in
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
            }
            posted.last = String(decoding: data, as: UTF8.self)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("job-1\n".utf8))
        }
        let model = HeadlessLaunchModel(headlessService: HeadlessService(network: NetworkClient(session: MockURLProtocol.mockSession())),
                                        recentLaunchStore: RecentLaunchStore())
        model.sessionName = "gpu-job"
        model.selectedImage = ImageParser.parse(RawImage(id: "images.canfar.net/skaha/terminal:1.1.2", types: ["headless"]))
        model.cmd = "nvidia-smi"
        return (model, posted)
    }

    func testTheJobCarriesItsGPUs() async {
        let (model, posted) = model()
        model.gpuOffer = staging
        model.resourceType = "fixed"
        model.gpus = 7
        await model.launch()
        XCTAssertTrue(posted.last.contains("gpus=7"), posted.last)
    }

    func testNoOfferClearsTheJobsGPUs() {
        let (model, _) = model()
        model.gpuOffer = staging
        model.gpus = 4
        model.gpuOffer = gapped
        XCTAssertEqual(model.gpus, 4, "still offered")
        model.gpuOffer = GPUOffer(options: [1, 2])
        XCTAssertEqual(model.gpus, 0, "no longer offered")
        model.gpus = 2
        model.gpuOffer = .none
        XCTAssertEqual(model.gpus, 0)
    }

    // MARK: - launch_headless_job

    private func plan(_ gpus: Int, offer: GPUOffer?) async throws -> ProposalPlan {
        try await LaunchHeadlessJobTool(offer: { offer }).plan(
            .init(name: "j", image: "images.canfar.net/skaha/terminal:1.1.2", cmd: "nvidia-smi", gpus: gpus),
            context: AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9)))
    }

    private func refusal(_ gpus: Int, offer: GPUOffer?) async -> String? {
        do {
            _ = try await plan(gpus, offer: offer)
            return nil
        } catch let failure as ToolFailureReason {
            if case .invalidArgument(let why) = failure { return why }
            return "\(failure)"
        } catch { return "\(error)" }
    }

    func testGPUsBeyondTheOptionsAreRefused() async {
        let why = await refusal(8, offer: staging)
        XCTAssertEqual(why, "gpus 8 is not offered: 0, or one of 1–7.")
        let gap = await refusal(3, offer: gapped)
        XCTAssertEqual(gap, "gpus 3 is not offered: 0, or one of 1, 2, 4.")
    }

    func testSevenGPUsAreSent() async throws {
        let planned = try await plan(7, offer: staging)
        let payload = try JSONDecoder().decode(LaunchHeadlessJobTool.Payload.self, from: planned.payload)
        XCTAssertEqual(payload.gpus, 7)
        let unknown = try await plan(3, offer: nil)
        XCTAssertEqual(try JSONDecoder().decode(LaunchHeadlessJobTool.Payload.self, from: unknown.payload).gpus, 3,
                       "the context not known: Skaha judges")
    }

    func testNoOfferRefusesGPUs() async {
        let why = await refusal(1, offer: GPUOffer.none)
        XCTAssertEqual(why, "This platform offers no GPUs.")
    }
}
