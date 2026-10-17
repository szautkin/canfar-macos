// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import ApplicationServices
import SwiftUI
import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 42 step 4, on screen: the Portal's three cards share one reload
/// button and one footer, and nothing in a card moves while it reloads, or
/// between its first load and the next.
@MainActor
final class PortalCardsLayoutTests: XCTestCase {

    // MARK: - A network the test holds

    /// Answers each card's request, after `hold` seconds; counts them.
    private final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var held: TimeInterval = 0
        private var counts: [String: Int] = [:]
        var hold: TimeInterval {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
        func count(_ what: String) -> Int { lock.withLock { counts[what, default: 0] } }
        func asked(_ what: String) { lock.withLock { counts[what, default: 0] += 1 } }
    }

    private static let stats = #"""
    {"cores": {"requestedCPUCores": 1164.4, "cpuCoresAvailable": 3000},
     "ram": {"requestedRAM": "11847.667G", "ramAvailable": "15032.386G"},
     "gpu": {"requestedGPU": 20, "gpuAvailable": 112, "maxGPU": 7}}
    """#
    private static let quota = """
    <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0" uri="vos://cadc.nrc.ca~arc/home/me"><vos:properties>
    <vos:property uri="ivo://ivoa.net/vospace/core#quota">1000000000000</vos:property>
    <vos:property uri="ivo://ivoa.net/vospace/core#length">250000000000</vos:property>
    </vos:properties></vos:node>
    """

    private func network() -> (Network, NetworkClient) {
        let network = Network()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            let (what, body): (String, String) = url.contains("view=stats") ? ("stats", Self.stats)
                : url.contains("/v1/session") ? ("jobs", "[]") : ("quota", Self.quota)
            network.asked(what)
            let hold = network.hold
            if hold > 0 { Thread.sleep(forTimeInterval: hold) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return (network, NetworkClient(session: MockURLProtocol.mockSession()))
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// A card, its model and what reloads it.
    private struct Card {
        let name: String
        let view: AnyView
        let reloadID: String
        let reload: @MainActor () async -> Void
    }

    private func cards(_ client: NetworkClient) async -> [Card] {
        let load = PlatformLoadModel(platformService: PlatformService(network: client))
        let storage = StorageModel(storageService: StorageService(network: client))
        let jobs = HeadlessMonitorModel(headlessService: HeadlessService(network: client))
        await load.loadStats()
        await storage.loadQuota(username: "me")
        await jobs.loadJobs()
        return [
            Card(name: "Platform Load", view: AnyView(PlatformLoadView(model: load)), reloadID: "portal.load.refresh",
                 reload: { await load.loadStats() }),
            Card(name: "Storage", view: AnyView(StorageQuotaView(model: storage)), reloadID: "portal.storage.refresh",
                 reload: { await storage.reload() }),
            Card(name: "Batch Jobs", view: AnyView(HeadlessJobsView(model: jobs)), reloadID: "portal.batchJobs.refresh",
                 reload: { await jobs.loadJobs() }),
        ]
    }

    // MARK: - Reading a card on screen

    private struct Seen {
        let all: [UIElement]
        let byID: [String: UIElement]
        /// Each named element's frame, by its name.
        let frames: [String: CGRect]
        /// What the card's elements cover.
        let bounds: CGRect
    }

    private func onScreen(_ view: AnyView, width: CGFloat = 323, capture: String? = nil, dark: Bool = false,
                          _ body: (_ source: AXElementSource, _ look: () async throws -> Seen,
                                   _ shot: (String) -> Void) async throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        /// The window as drawn, to the folder VERBINAL_TEST_CAPTURES names.
        func shot(_ name: String) {
            guard let folder = ProcessInfo.processInfo.environment["VERBINAL_TEST_CAPTURES"],
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        window.contentView = NSHostingView(rootView: view.groupBoxStyle(PortalCardStyle()).padding(8)
            .frame(width: width, alignment: .top).uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "portal" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(700))
        try await body(source, {
            if let capture { shot(capture) }
            let snapshot = source.snapshot()
            let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
            let elements = snapshot.elements(in: ref.index)
            var frames: [String: CGRect] = [:]
            for element in elements { if let name = element.name { frames[name] = element.frame } }
            return Seen(all: elements, byID: Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                        frames: frames, bounds: elements.map(\.frame).reduce(CGRect.null) { $0.union($1) })
        }, shot)
    }

    private func same(_ a: CGRect, _ b: CGRect, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y, edge) in [(a.minX, b.minX, "left"), (a.maxX, b.maxX, "right"), (a.minY, b.minY, "top"), (a.maxY, b.maxY, "bottom")] {
            XCTAssertEqual(x, y, accuracy: 0.5, "\(what): its \(edge) moved, \(a) → \(b)", file: file, line: line)
        }
    }

    // MARK: - The tests

    func testEachCardHasTheSameReloadButton() async throws {
        try await AXReadable.require()
        let (_, client) = network()
        let names = ["portal.load.refresh": "Refresh platform stats", "portal.storage.refresh": "Refresh storage",
                     "portal.batchJobs.refresh": "Refresh batch jobs"]
        for card in await cards(client) {
            try await onScreen(card.view) { _, look, _ in
                let seen = try await look()
                let button = try XCTUnwrap(seen.byID[card.reloadID], card.name)
                XCTAssertEqual(button.name, names[card.reloadID], card.name)
                XCTAssertEqual(button.kind, .button, card.name)
                XCTAssertTrue(button.enabled, card.name)
                XCTAssertEqual(button.frame.width, PortalReloadButton.slot, accuracy: 6, "one slot, every card")
            }
        }
    }

    /// Loaded, then reloading (the network held), then loaded again: the
    /// reload button stays where it is, every element that keeps its words
    /// keeps its frame, and the card covers the same space.
    func testNothingMovesWhileACardReloads() async throws {
        try await AXReadable.require()
        let (network, client) = network()
        for card in await cards(client) {
            try await onScreen(card.view, capture: "card-\(card.reloadID)") { _, look, _ in
                let before = try await look()
                network.hold = 1.5
                let reloading = Task { await card.reload() }
                try await Task.sleep(for: .milliseconds(500))
                let during = try await look()
                network.hold = 0
                await reloading.value
                try await Task.sleep(for: .milliseconds(400))
                let after = try await look()

                let button = { (seen: Seen) in seen.byID[card.reloadID]?.frame ?? .null }
                same(button(before), button(during), "\(card.name)'s reload button, reloading")
                XCTAssertFalse(during.byID[card.reloadID]?.enabled ?? true, "\(card.name): disabled while it reloads")
                same(button(before), button(after), "\(card.name)'s reload button, after")
                for (name, frame) in before.frames {
                    if let still = during.frames[name] { same(frame, still, "\(card.name): \(name), reloading") }
                }
                same(before.bounds, during.bounds, "\(card.name), reloading")
                same(before.bounds, after.bounds, "\(card.name), after")
            }
        }
    }

    /// The first load, held: the card is already as tall as it will be.
    func testACardIsAsTallBeforeItsFirstLoad() async throws {
        try await AXReadable.require()
        let (network, client) = network()
        let views: [(String, AnyView, @MainActor () async -> Void)] = {
            let load = PlatformLoadModel(platformService: PlatformService(network: client))
            let storage = StorageModel(storageService: StorageService(network: client))
            let jobs = HeadlessMonitorModel(headlessService: HeadlessService(network: client))
            return [("Platform Load", AnyView(PlatformLoadView(model: load)), { await load.loadStats() }),
                    ("Storage", AnyView(StorageQuotaView(model: storage)), { await storage.loadQuota(username: "me") }),
                    ("Batch Jobs", AnyView(HeadlessJobsView(model: jobs)), { await jobs.loadJobs() })]
        }()
        for (name, view, load) in views {
            try await onScreen(view, capture: "first-\(name)") { _, look, _ in
                network.hold = 1.5
                let loading = Task { await load() }
                try await Task.sleep(for: .milliseconds(500))
                let first = try await look()
                network.hold = 0
                await loading.value
                try await Task.sleep(for: .milliseconds(400))
                let loaded = try await look()
                XCTAssertEqual(first.bounds.height, loaded.bounds.height, accuracy: 0.5, "\(name): as tall before its first load")
            }
        }
    }

    /// Storage's new reload button asks for the quota again, and its
    /// footer moves on.
    func testStorageReloads() async throws {
        try await AXReadable.require()
        let (network, client) = network()
        let storage = StorageModel(storageService: StorageService(network: client))
        await storage.loadQuota(username: "me")
        let first = try XCTUnwrap(storage.load.value)
        try await onScreen(AnyView(StorageQuotaView(model: storage))) { source, look, _ in
            let seen = try await look()
            let button = try XCTUnwrap(seen.byID["portal.storage.refresh"])
            let target = try XCTUnwrap(source.element(button.handle))
            try await Task.sleep(for: .milliseconds(1100))   // a second on, for "Updated" to move
            XCTAssertEqual(AXUIElementPerformAction(target, kAXPressAction as CFString), .success)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(network.count("quota"), 2)
            XCTAssertGreaterThan(try XCTUnwrap(storage.load.value), first)
        }
    }

    func testTheFooterSaysWhen() async throws {
        try await AXReadable.require()
        let (_, client) = network()
        let jobs = HeadlessMonitorModel(headlessService: HeadlessService(network: client))
        await jobs.loadJobs()
        jobs.isPolling = true
        jobs.pollCountdown = 32
        for card in await cards(client).dropLast() + [Card(name: "Batch Jobs", view: AnyView(HeadlessJobsView(model: jobs)),
                                                            reloadID: "portal.batchJobs.refresh", reload: {})] {
            try await onScreen(card.view) { _, look, _ in
                let seen = try await look()
                let footer = seen.frames.keys.first { $0.hasPrefix("Updated ") }
                let text = try XCTUnwrap(footer, "\(card.name): no \"Updated …\"")
                if card.name == "Batch Jobs" { XCTAssertTrue(text.hasSuffix(" · next in 32 s"), text) }
            }
        }
    }

    // MARK: - The live check (2026-10-16)

    /// The footer's time is the clock's, in 24 hours as the rest of the
    /// Portal: where the locale counts in twelve, it had read "07:18:36" at
    /// 19:18:36, with no AM or PM.
    func testTheFooterTellsTheTimeIn24Hours() throws {
        let evening = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16,
                                                                                  hour: 19, minute: 18, second: 36)))
        XCTAssertEqual(PortalCardFooter.line(updated: evening, working: false, next: nil), "Updated 19:18:36")
        XCTAssertEqual(PortalCardFooter.line(updated: evening, working: true, next: "next in 8 s"), "Updated 19:18:36 · next in 8 s")
        XCTAssertEqual(PortalCardFooter.line(updated: nil, working: true, next: nil), "Loading…")
        XCTAssertEqual(PortalCardFooter.line(updated: nil, working: false, next: nil), "—")
        XCTAssertEqual(PortalCardFooter.line(updated: nil, working: false, next: "next in 8 s"), "next in 8 s")
    }

    /// The three cards side by side, as the Portal's top row has them: their
    /// titles and reload buttons on one line, and their footers on another,
    /// at each card's foot whatever its body holds. Batch Jobs' title stood
    /// a point lower, beside its taller button, and the footers at three
    /// heights.
    func testTheRowLinesUp() async throws {
        try await AXReadable.require()
        let (_, client) = network()
        let cards = await cards(client)
        let row = AnyView(Grid(alignment: .topLeading, horizontalSpacing: 16) {
            GridRow(alignment: .top) {
                ForEach(cards.indices, id: \.self) { index in
                    cards[index].view.frame(width: 323).frame(maxHeight: .infinity, alignment: .top)
                }
            }
        })
        try await onScreen(row, width: 1001, capture: "cards-row") { _, look, _ in
            let seen = try await look()
            func line(_ frames: [CGRect], _ what: String, _ edge: (CGRect) -> CGFloat) {
                XCTAssertEqual(frames.count, 3, "\(what): \(frames)")
                for frame in frames.dropFirst() { XCTAssertEqual(edge(frame), edge(frames[0]), accuracy: 0.5, "\(what): \(frames)") }
            }
            line(["Platform Load", "Storage", "Batch Jobs"].compactMap { name in seen.all.first { $0.name == name }?.frame },
                 "the titles", \.midY)
            line(cards.compactMap { seen.byID[$0.reloadID]?.frame }, "the reload buttons", \.minY)
            line(seen.all.filter { $0.name?.hasPrefix("Updated ") == true }.map(\.frame), "the footers", \.minY)
        }
    }

    // MARK: - Storage's bar, on a reload (the person's ask, 2026-10-16)

    /// On a reload the bar runs back to the start, and fills to the usage
    /// when it comes; with Reduce Motion it stands still, at the usage.
    func testStoragesBarRunsBackWhileItReloads() {
        XCTAssertEqual(StorageQuotaView.bar(usage: 79, refreshing: true, reduceMotion: false), 0)
        XCTAssertEqual(StorageQuotaView.bar(usage: 79, refreshing: false, reduceMotion: false), 79)
        XCTAssertEqual(StorageQuotaView.bar(usage: 79, refreshing: true, reduceMotion: true), 79)
        XCTAssertEqual(StorageQuotaView.bar(usage: 104, refreshing: false, reduceMotion: false), 100, "never past full")
    }

    /// Pictures of the bar on a reload, to look at: running back, at the
    /// start while it waits, filling, and full again — light and dark.
    func testStoragesBarOnScreen() async throws {
        try await AXReadable.require()
        let (network, client) = network()
        let storage = StorageModel(storageService: StorageService(network: client))
        await storage.loadQuota(username: "me")
        for dark in [false, true] {
            try await onScreen(AnyView(StorageQuotaView(model: storage)), dark: dark) { _, look, shot in
                let suffix = dark ? "-dark" : ""
                let before = try await look()
                network.hold = 1.2
                let reloading = Task { await storage.reload() }
                try await Task.sleep(for: .milliseconds(120))
                shot("storage-bar-1-running-back\(suffix)")
                try await Task.sleep(for: .milliseconds(600))
                shot("storage-bar-2-waiting\(suffix)")
                network.hold = 0
                await reloading.value
                try await Task.sleep(for: .milliseconds(250))
                shot("storage-bar-3-filling\(suffix)")
                try await Task.sleep(for: .milliseconds(1200))
                shot("storage-bar-4-full\(suffix)")
                let after = try await look()
                same(before.bounds, after.bounds, "Storage, after its bar ran")
            }
        }
    }

    // MARK: - Refreshing, seen (step 5)

    func testTheRingsSpinOnlyWithoutReduceMotion() {
        XCTAssertTrue(LoadDonutView.spins(refreshing: true, reduceMotion: false))
        XCTAssertFalse(LoadDonutView.spins(refreshing: true, reduceMotion: true))
        XCTAssertFalse(LoadDonutView.spins(refreshing: false, reduceMotion: false))
    }

    /// While Platform Load refreshes, each ring says so — no percentage —
    /// and after, its numbers are back. Pictures mid-refresh, light and
    /// dark, at the narrowest card and a whole window.
    func testTheRingsSayTheyAreRefreshing() async throws {
        try await AXReadable.require()
        let (network, client) = network()
        let load = PlatformLoadModel(platformService: PlatformService(network: client))
        await load.loadStats()
        for (width, dark) in [(CGFloat(323), false), (323, true), (1000, false)] {
            let name = "refreshing-\(Int(width))\(dark ? "-dark" : "")"
            try await onScreen(AnyView(PlatformLoadView(model: load)), width: width, dark: dark) { _, look, shot in
                network.hold = 1.5
                let reloading = Task { await load.loadStats() }
                try await Task.sleep(for: .milliseconds(500))
                shot(name)
                let during = try await look()
                for id in ["portal.load.cpu", "portal.load.ram", "portal.load.gpu"] {
                    XCTAssertEqual(during.byID[id]?.help, "Refreshing", "\(id) at \(width)")
                }
                network.hold = 0
                await reloading.value
                try await Task.sleep(for: .milliseconds(400))
                let after = try await look()
                XCTAssertEqual(after.byID["portal.load.cpu"]?.help, "39%, 1,836 of 3,000 cores free")
                XCTAssertEqual(after.byID["portal.load.gpu"]?.help, "18%, 92 of 112 GPUs free")
            }
        }
    }

    /// Storage and Batch Jobs mid-refresh, for looking at: the figures stay,
    /// dimmed.
    func testTheOtherCardsDimWhileTheyRefresh() async throws {
        try await AXReadable.require()
        let (network, client) = network()
        for card in await cards(client).dropFirst() {
            try await onScreen(card.view) { _, look, shot in
                let before = try await look()
                network.hold = 1.5
                let reloading = Task { await card.reload() }
                try await Task.sleep(for: .milliseconds(500))
                shot("refreshing-\(card.reloadID)")
                let during = try await look()
                network.hold = 0
                await reloading.value
                for (name, frame) in before.frames where name != "Refresh storage" && name != "Refresh batch jobs" {
                    XCTAssertNotNil(during.frames[name], "\(card.name): \(name) stays while it refreshes")
                    if let still = during.frames[name] { same(frame, still, "\(card.name): \(name)") }
                }
            }
        }
    }
}
