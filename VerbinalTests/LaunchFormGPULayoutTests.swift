// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 41 step 3, on screen: the launch form's Use a GPU, as the person and
/// an assistant find it — enabled where the platform offers GPUs, greyed
/// where not — and the form still in its sheet at its narrowest.
@MainActor
final class LaunchFormGPULayoutTests: XCTestCase {

    private struct NoLaunch: SessionLaunching {
        func launchSession(_ params: SessionLaunchParams) async throws -> String? { nil }
    }

    private func model(offer: GPUOffer) -> SessionLaunchModel {
        let model = SessionLaunchModel(sessionService: NoLaunch(),
                                       imageService: ImageService(network: NetworkClient(session: .shared)),
                                       recentLaunchStore: RecentLaunchStore())
        model.coreOptions = [1, 2, 4]
        model.ramOptions = [4, 8, 16]
        model.gpuOffer = offer
        return model
    }

    /// The form in a window as wide as its sheet at its narrowest (620);
    /// `body` reads its elements by id and by name, and the controls that
    /// spill out of the window.
    private func form(_ model: SessionLaunchModel, batch: HeadlessLaunchModel? = nil, tab: AppState.LaunchFormTab? = nil,
                      capture: String,
                      _ body: (_ byID: [String: UIElement], _ names: [String], _ spilled: [String]) throws -> Void) async throws {
        let state = AppState(marks: MarkStore(persistence: nil))
        if batch != nil { state.launchFormTab = .headless }
        if let tab { state.launchFormTab = tab }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 80, width: 620, height: 640), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ScrollView { LaunchFormView(model: model, headlessModel: batch).padding(20) }
            .environment(state)
            .uiWindowPlace(.main))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "portal" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(900))
        if let folder = ProcessInfo.processInfo.environment["VERBINAL_TEST_CAPTURES"],
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(capture).png"))
        }
        let snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
        let elements = snapshot.elements(in: ref.index)
        var spilled: [String] = []
        func walk(_ view: NSView) {
            if view is NSControl, !view.isHiddenOrHasHiddenAncestor {
                let frame = view.convert(view.bounds, to: host)
                if frame.minX < -1.5 || frame.maxX > host.bounds.width + 1.5 { spilled.append("\(type(of: view)) \(frame)") }
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        try body(Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                 elements.compactMap(\.name), spilled)
    }

    func testTheCheckboxIsEnabledWhereGPUsAreOffered() async throws {
        try await AXReadable.require()
        try await form(model(offer: GPUOffer(options: Array(1...7))), capture: "launch-gpu-offered") { byID, _, spilled in
            let box = try XCTUnwrap(byID["portal.launch.gpu"], "\(byID.keys.sorted())")
            XCTAssertEqual(box.name, "Use a GPU")
            XCTAssertTrue(box.enabled)
            XCTAssertEqual(box.help, "One GPU for this session; the resources become Fixed")
            XCTAssertEqual(spilled, [])
        }
    }

    func testTheCheckboxIsGreyWhereNoneAreOffered() async throws {
        try await AXReadable.require()
        try await form(model(offer: .none), capture: "launch-gpu-none") { byID, _, _ in
            let box = try XCTUnwrap(byID["portal.launch.gpu"])
            XCTAssertFalse(box.enabled)
            XCTAssertEqual(box.help, "This platform offers no GPUs")
        }
    }

    /// Ticked: Fixed, with the cores and RAM to choose, and no GPU stepper —
    /// an interactive session's one GPU is the checkbox's.
    func testTickedItShowsTheFixedSizesAndNoStepper() async throws {
        try await AXReadable.require()
        let model = model(offer: GPUOffer(options: Array(1...7)))
        model.usesAGPU = true
        try await form(model, capture: "launch-gpu-ticked") { _, names, spilled in
            XCTAssertTrue(names.contains("CPU Cores"), "\(names)")
            XCTAssertFalse(names.contains("GPUs"), "no stepper for an interactive session")
            XCTAssertEqual(spilled, [])
        }
    }

    /// The batch tab, Fixed: its GPU stepper, through what is offered, and
    /// greyed where nothing is.
    func testTheBatchTabsStepperFollowsTheOffer() async throws {
        try await AXReadable.require()
        for offer in [GPUOffer(options: Array(1...7)), .none] {
            let batch = HeadlessLaunchModel(headlessService: HeadlessService(network: NetworkClient(session: .shared)),
                                            recentLaunchStore: RecentLaunchStore())
            batch.resourceType = "fixed"
            try await form(model(offer: offer), batch: batch, capture: offer.offersAny ? "batch-gpus" : "batch-no-gpus") { byID, _, spilled in
                XCTAssertEqual(spilled, [])
                let stepper = try XCTUnwrap(byID.values.first { $0.name == "GPUs" && $0.kind == .stepper }, "\(byID.values.compactMap(\.name))")
                XCTAssertEqual(stepper.enabled, offer.offersAny)
                XCTAssertEqual(stepper.help, offer.offersAny ? "0, or one of the counts the platform offers" : "This platform offers no GPUs")
                XCTAssertNil(byID["portal.launch.gpu"], "no checkbox on the batch tab")
            }
        }
    }

    /// Plan 42: the Advanced tab, Fixed, has the GPU stepper through what is
    /// offered — greyed where nothing is — and no checkbox.
    func testTheAdvancedTabHasTheStepper() async throws {
        try await AXReadable.require()
        for offer in [GPUOffer(options: Array(1...7)), .none] {
            let model = model(offer: offer)
            model.resourceType = "fixed"
            try await form(model, tab: .advanced, capture: offer.offersAny ? "advanced-gpus" : "advanced-no-gpus") { byID, _, spilled in
                XCTAssertEqual(spilled, [])
                let stepper = try XCTUnwrap(byID.values.first { $0.name == "GPUs" && $0.kind == .stepper }, "\(byID.values.compactMap(\.name))")
                XCTAssertEqual(stepper.enabled, offer.offersAny)
                XCTAssertNil(byID["portal.launch.gpu"], "no checkbox on the Advanced tab")
            }
        }
    }

    /// The GPU stepper stands in the cores' and RAM's column, on the Advanced
    /// tab and the batch one — it had stood at the row's far end — and says
    /// what it takes without calling a session a job (live check, 2026-10-16).
    func testTheGPUStepperStandsWithTheOthers() async throws {
        try await AXReadable.require()
        let offer = GPUOffer(options: Array(1...7))
        let session = model(offer: offer)
        session.resourceType = "fixed"
        let batch = HeadlessLaunchModel(headlessService: HeadlessService(network: NetworkClient(session: .shared)),
                                        recentLaunchStore: RecentLaunchStore())
        batch.resourceType = "fixed"
        let tabs: [(AppState.LaunchFormTab, HeadlessLaunchModel?)] = [(.advanced, nil), (.headless, batch)]
        for (tab, batch) in tabs {
            try await form(session, batch: batch, tab: tab, capture: "gpu-column-\(tab)") { byID, _, _ in
                let steppers = byID.values.filter { $0.kind == .stepper }
                let cores = try XCTUnwrap(steppers.first { $0.name == "CPU Cores" }, "\(tab)")
                let gpus = try XCTUnwrap(steppers.first { $0.name == "GPUs" }, "\(tab)")
                XCTAssertEqual(gpus.frame.minX, cores.frame.minX, accuracy: 1, "\(tab): \(gpus.frame) under \(cores.frame)")
                XCTAssertEqual(gpus.help, "0, or one of the counts the platform offers", "\(tab)")
            }
        }
    }
}
