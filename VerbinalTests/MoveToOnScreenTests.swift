// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Plan 46 M2, on screen: Move To… left of Remove File…, on while signed in
/// to CANFAR; and its sheet saying where each file goes and what the button
/// does — read as the person sees it, as an assistant reads it.
@MainActor
final class MoveToOnScreenTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("move-to-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func record(cutout: Bool = false) -> DownloadedObservation {
        let file = folder.appendingPathComponent(cutout ? "745234p.cutout-qa46.fits" : "745234p.fits.fz")
        FileManager.default.createFile(atPath: file.path, contents: Data("SIMPLE".utf8))
        var record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?745234/745234p", collection: "CFHT",
                                           observationID: "745234", targetName: "D2", instrument: "MegaPrime",
                                           filter: "r", ra: "", dec: "", startDate: "", calLevel: "2", localPath: file.path)
        record.fileSize = 6
        return record
    }

    private func show(_ view: some View, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: width, height: height).uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func elements(of window: NSWindow) async throws -> [UIElement] {
        let source = AXElementSource(screenName: { _, _, _ in "research" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(700))
        let snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
        return snapshot.elements(in: ref.index)
    }

    func testMoveToSitsLeftOfRemoveFileWhileSignedIn() async throws {
        try await AXReadable.require()
        let state = AppState()
        state.researchModel.transfer.storage = ResearchFileTransferTests.FakeStorage()
        let window = show(ObservationDetailView(observation: record(), model: state.researchModel), width: 1000, height: 700)
        defer { window.close() }
        var all = try await elements(of: window)
        let move = try XCTUnwrap(all.first { $0.name == "Move To…" }, "\(all.compactMap(\.name))")
        let remove = try XCTUnwrap(all.first { $0.name == "Remove File…" })
        XCTAssertLessThan(move.frame.minX, remove.frame.minX, "left of Remove File…")
        XCTAssertTrue(move.enabled)
        XCTAssertEqual(move.id, "research.moveTo")

        state.researchModel.transfer.storage = nil
        all = try await elements(of: window)
        let off = try XCTUnwrap(all.first { $0.name == "Move To…" })
        XCTAssertFalse(off.enabled, "signed out: off")
    }

    func testTheSheetSaysWhereEachFileGoesAndWhatTheButtonDoes() async throws {
        try await AXReadable.require()
        let state = AppState()
        let research = state.researchModel
        research.transfer.storage = ResearchFileTransferTests.FakeStorage()
        let sheet = MoveToModel(record: record(cutout: true), transfer: research.transfer, store: research.observationStore)
        let window = show(MoveToSheet(model: sheet) {}, width: 600, height: 520)
        defer { window.close() }
        var all = try await elements(of: window)
        var names = all.compactMap(\.name)
        for name in ["Move To", "To Your Storage", "745234p.cutout-qa46.fits", "Copy to Storage",
                     "Copy — keep it on this Mac too", "Move — remove it from this Mac once it is in your storage"] {
            XCTAssertTrue(names.contains(name), "\(name): \(names)")
        }
        XCTAssertTrue(names.contains { $0.hasSuffix(" to your storage") }, "the summary: \(names)")
        XCTAssertTrue(all.contains { $0.id == "research.moveTo.run" && $0.enabled })

        sheet.plan.keepCopy = false
        all = try await elements(of: window)
        names = all.compactMap(\.name)
        XCTAssertTrue(names.contains("Move to Storage"), "\(names)")
        XCTAssertTrue(names.contains("The copy on this Mac is removed once the one in your storage is there."), "\(names)")
    }

    // MARK: - M3: the record's buttons over all of its files

    /// A cutout with its weight map, one kept in storage too.
    private func twoFiles() -> DownloadedObservation {
        let weight = folder.appendingPathComponent("745234p.cutout-qa46.weight.fits")
        FileManager.default.createFile(atPath: weight.path, contents: Data("SIMPLE".utf8))
        var main = record(cutout: true)
        main.storagePath = "Verbinal-Results/research/745234p.cutout-qa46.fits"
        return main.keeping(KeptFile(name: weight.lastPathComponent, localPath: weight.path, size: 6, downloadedAt: Date()))
    }

    func testRevealInFinderShowsEveryFileOnThisMac() {
        let urls = AppState().researchModel.revealURLs(twoFiles())
        XCTAssertEqual(urls.map(\.lastPathComponent), ["745234p.cutout-qa46.fits", "745234p.cutout-qa46.weight.fits"])
    }

    func testRemoveFilesAsksWhichAndSaysWhatIsLost() async throws {
        try await AXReadable.require()
        let state = AppState()
        let record = twoFiles()
        let detail = show(ObservationDetailView(observation: record, model: state.researchModel), width: 1000, height: 700)
        let names = try await elements(of: detail).compactMap(\.name)
        detail.close()
        XCTAssertTrue(names.contains("Remove Files…"), "several files: \(names)")

        let window = show(RemoveFilesSheet(observation: record, model: state.researchModel) {}, width: 520, height: 300)
        defer { window.close() }
        let all = try await elements(of: window)
        let read = all.compactMap(\.name)
        for name in ["Remove Files from This Mac", "745234p.cutout-qa46.fits, A copy stays in your storage",
                     "745234p.cutout-qa46.weight.fits, Its only copy: removing it loses it", "Remove File"] {
            XCTAssertTrue(read.contains(name), "\(name): \(read)")
        }
        // "Remove File", one: its only copy starts unchecked.
    }
}
