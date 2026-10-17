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

/// Plan 41 step 2, on screen: the platform load's three rings, read as the
/// person and an assistant read them, inside the card at its narrowest and
/// widest, with GPUs and without.
@MainActor
final class PlatformLoadLayoutTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private let withGPUs = #"""
    {"cores": {"requestedCPUCores": 1164.4, "cpuCoresAvailable": 3000},
     "ram": {"requestedRAM": "11847.667G", "ramAvailable": "15032.386G"},
     "gpu": {"requestedGPU": 20, "gpuAvailable": 112, "maxGPU": 7}}
    """#
    private let withoutGPUs = #"""
    {"cores": {"requestedCPUCores": 1164.4, "cpuCoresAvailable": 3000},
     "ram": {"requestedRAM": "11847.667G", "ramAvailable": "15032.386G"}}
    """#

    private func loaded(_ body: String) async -> PlatformLoadModel {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = PlatformLoadModel(platformService: PlatformService(network: NetworkClient(session: MockURLProtocol.mockSession())))
        await model.loadStats()
        return model
    }

    /// The card in a window `width` wide, as the Portal draws it; `body`
    /// reads its rings: id → (frame, help), and the window's width.
    private func card(_ model: PlatformLoadModel, width: CGFloat, capture: String? = nil, dark: Bool = false,
                      _ body: ([String: UIElement], CGFloat) throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: PlatformLoadView(model: model)
            .groupBoxStyle(PortalCardStyle())
            .padding(8)
            .frame(width: width, alignment: .top)
            .uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "portal" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(800))
        if let capture { Self.capture(window, capture) }
        let snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
        let ringIDs: Set = ["portal.load.cpu", "portal.load.ram", "portal.load.gpu"]
        let rings = Dictionary(snapshot.elements(in: ref.index).filter { ringIDs.contains($0.id) }.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        try body(rings, width)
    }

    /// For looking at: the window as drawn, to the scratch folder the
    /// environment names (VERBINAL_TEST_CAPTURES), when it names one.
    private static func capture(_ window: NSWindow, _ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["VERBINAL_TEST_CAPTURES"],
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    func testThreeRingsWithTheirNumbers() async throws {
        try await AXReadable.require()
        let model = await loaded(withGPUs)
        try await card(model, width: 420, capture: "load-gpus") { rings, _ in
            XCTAssertEqual(rings.keys.sorted(), ["portal.load.cpu", "portal.load.gpu", "portal.load.ram"])
            XCTAssertEqual(rings["portal.load.cpu"]?.name, "CPU load")
            XCTAssertEqual(rings["portal.load.cpu"]?.help, "39%, 1,836 of 3,000 cores free")
            XCTAssertEqual(rings["portal.load.ram"]?.help, "79%, 3,185 of 15,032 GB free")
            XCTAssertEqual(rings["portal.load.gpu"]?.help, "18%, 92 of 112 GPUs free")
        }
    }

    func testTheGPURingIsGreyWithoutData() async throws {
        try await AXReadable.require()
        let model = await loaded(withoutGPUs)
        for dark in [false, true] {
            try await card(model, width: 420, capture: dark ? "load-no-gpus-dark" : "load-no-gpus", dark: dark) { rings, _ in
                XCTAssertEqual(rings["portal.load.gpu"]?.help, "This platform does not report GPUs yet")
                XCTAssertEqual(rings["portal.load.cpu"]?.help, "39%, 1,836 of 3,000 cores free", "CPU and RAM as before")
            }
        }
    }

    /// At the Portal's narrowest card (a third of a 1,000-point window), an
    /// iPhone's width, and a whole window: every ring inside the card, none
    /// overlapping another.
    func testTheRingsFitTheNarrowestCard() async throws {
        try await AXReadable.require()
        let model = await loaded(withGPUs)
        for width: CGFloat in [323, 240, 1000] {
            try await card(model, width: width, capture: "load-\(Int(width))") { rings, room in
                XCTAssertEqual(rings.count, 3, "\(width)")
                for (id, ring) in rings {
                    XCTAssertGreaterThanOrEqual(ring.frame.minX, -0.5, "\(id) at \(width)")
                    XCTAssertLessThanOrEqual(ring.frame.maxX, room + 0.5, "\(id) at \(width): \(ring.frame)")
                }
                let frames = rings.values.map(\.frame)
                for (i, a) in frames.enumerated() { for b in frames.dropFirst(i + 1) {
                    XCTAssertFalse(a.intersects(b), "rings overlap at \(width): \(a) \(b)")
                } }
            }
        }
    }
}
