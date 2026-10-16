// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Plan 40 step 4: an open discovery sheet hears the package lists a new
/// device's sync brings, without a reopen, and cheaply — the rows at most
/// once a second, the filters (a `List` of thousands of rows) once.
@MainActor
final class ImageDiscoveryArrivalsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("arrivals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func coordinator() -> ImageDiscoveryCoordinator {
        ImageDiscoveryCoordinator(store: JSONManifestStore(directory: directory),
                                  headless: ImageDiscoveryCoordinatorTests.MockHeadless(),
                                  vospace: ImageDiscoveryCoordinatorTests.MockVOSpace(), username: "me")
    }

    private nonisolated func list(_ imageID: String, packages: [String]) -> Data {
        let body: [String: Any] = [
            "schemaVersion": ProbeScript.schemaVersion, "imageID": imageID, "contentHash": "sha256:test",
            "capturedAt": "2026-10-15T12:00:00Z", "osFamily": "ubuntu", "osVersion": "24.04", "kernel": "Linux",
            "dpkgPackages": [], "rpmPackages": [], "apkPackages": [], "rPackages": [], "condaEnvs": [],
            "pythonPackages": packages.map { ["name": $0, "version": "1.0", "source": "pip", "env": ""] },
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func images(_ ids: [String]) -> [ParsedImage] {
        ids.map { ImageParser.parse(RawImage(id: $0, types: ["notebook"])) }
    }

    private func until(_ seconds: TimeInterval, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    func testAnOpenSheetHearsAListArriveAndItsPackagesOnceTheyStop() async throws {
        let coordinator = coordinator()
        let model = ImageDiscoveryModel(coordinator: coordinator)
        let ids = ["images.canfar.net/skaha/astroml:24.07", "images.canfar.net/skaha/casa:6.6"]
        await model.onAppear(catalogue: images(ids))
        try await Task.sleep(for: .milliseconds(100))   // its listening is set up
        XCTAssertEqual(model.rowStates[ids[0]], .neverDiscovered)

        _ = await coordinator.importManifest(list(ids[0], packages: ["astropy"]))
        try await until(3) { if case .discovered = model.rowStates[ids[0]] { true } else { false } }
        guard case .discovered = model.rowStates[ids[0]] else { return XCTFail("the row did not turn") }
        XCTAssertFalse(model.allPackages.python.contains("astropy"), "the filters wait for the lists to stop")
        try await until(4) { model.allPackages.python.contains("astropy") }
        XCTAssertTrue(model.allPackages.python.contains("astropy"))
        XCTAssertEqual(model.filterUpdates, 1)
    }

    func testThreeHundredListsChangeTheFiltersOnceAndTheRowsAtMostOnceASecond() async throws {
        let coordinator = coordinator()
        let model = ImageDiscoveryModel(coordinator: coordinator)
        let ids = (1...300).map { "images.canfar.net/skaha/image-\($0):1.0" }
        await model.onAppear(catalogue: images(ids))
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        for (index, id) in ids.enumerated() {
            _ = await coordinator.importManifest(list(id, packages: ["package-\(index)", "numpy"]))
        }
        try await until(6) { model.filterUpdates == 1 }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(model.filterUpdates, 1, "the filters once, when the lists stopped")
        XCTAssertLessThanOrEqual(model.rowUpdates, Int(seconds.rounded(.up)) + 1, "the rows at most once a second")
        XCTAssertEqual(model.rowStates.values.filter { if case .discovered = $0 { true } else { false } }.count, 300)
        XCTAssertEqual(model.allPackages.python.count, 301)
    }

    func testAClosedSheetDoesNothing() async throws {
        let coordinator = coordinator()
        let model = ImageDiscoveryModel(coordinator: coordinator)
        let id = "images.canfar.net/skaha/astroml:24.07"
        await model.onAppear(catalogue: images([id]))
        model.onDisappear()
        try await Task.sleep(for: .milliseconds(100))
        _ = await coordinator.importManifest(list(id, packages: ["astropy"]))
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(model.rowStates[id], .neverDiscovered, "closed: it reads the cache when it opens again")
        XCTAssertEqual(model.rowUpdates, 0)
    }

    /// On screen: the header's count follows the lists as they come.
    func testTheHeaderCountsTheListsAsTheyCome() async throws {
        try await AXReadable.require()
        let coordinator = coordinator()
        let model = ImageDiscoveryModel(coordinator: coordinator)
        let ids = ["images.canfar.net/skaha/astroml:24.07", "images.canfar.net/skaha/casa:6.6"]
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ImageDiscoverySheet(model: model, onPick: { _ in }, catalogue: images(ids))
            .uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "discovery" })
        await source.ready()
        func header() async throws -> [String] {
            let snapshot = source.snapshot()
            let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
            return snapshot.elements(in: ref.index).compactMap(\.name).filter { $0.hasPrefix("Discovered") }
        }
        try await Task.sleep(for: .milliseconds(800))
        var shown = try await header()
        XCTAssertEqual(shown, ["Discovered 0 of 2 images"])
        _ = await coordinator.importManifest(list(ids[0], packages: ["astropy"]))
        try await Task.sleep(for: .milliseconds(1800))
        shown = try await header()
        XCTAssertEqual(shown, ["Discovered 1 of 2 images"])
    }
}
