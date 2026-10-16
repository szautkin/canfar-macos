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

/// QA 2026-10-15, handout 29 2.5 (plan 39 step 5): a folded collection on
/// the Research screen is a section that `open_ui` opens by its name, with
/// its observations `inside`, and `close_ui` folds again.
@MainActor
final class ResearchCollectionsOnScreenTests: XCTestCase {
    private let foldedKey = "research.collapsedCollections"
    private var foldedBefore: String?

    override func setUp() async throws {
        foldedBefore = UserDefaults.standard.string(forKey: foldedKey)
    }

    override func tearDown() async throws {
        if let foldedBefore { UserDefaults.standard.set(foldedBefore, forKey: foldedKey) }
        else { UserDefaults.standard.removeObject(forKey: foldedKey) }
    }

    private func record(_ id: String, target: String, collection: String) -> DownloadedObservation {
        DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/\(collection)?\(id)/\(id)", collection: collection,
                              observationID: id, targetName: target, instrument: "ACS", filter: "",
                              ra: "", dec: "", startDate: "", calLevel: "", localPath: "")
    }

    func testAFoldedCollectionOpensByItsNameAndFoldsAgain() async throws {
        try await AXReadable.require()
        UserDefaults.standard.set("HST", forKey: foldedKey)
        let store = ObservationStore(fileName: "test-collections-\(UUID().uuidString).json", spotlight: nil)
        _ = store.keep(record("2001", target: "M31", collection: "HST"))
        _ = store.keep(record("2002", target: "M33", collection: "HST"))
        _ = store.keep(record("3001", target: "Vega", collection: "CFHT"))
        let notes = ObservationNoteStore(database: try AppDatabase.makeInMemory(), legacyNotesSource: nil)
        let model = ResearchModel(observationStore: store, downloadService: DownloadService(), noteStore: notes)
        let state = AppState()
        state.currentMode = .research

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DownloadedFilesView(model: model)
            .environment(state).uiWindowPlace(.main))
        window.orderFrontRegardless()
        defer { window.close() }
        await state.uiHintPresenter.ready()
        try await Task.sleep(for: .milliseconds(500))

        // Listed as a section that opens, not as a value.
        let listed = state.uiHintPresenter.snapshot().elements
        let folded = try XCTUnwrap(listed.first { $0.name?.hasPrefix("HST") == true && $0.kind == .disclosure },
                                   "\(listed.map { "\($0.kind.rawValue) \($0.name ?? "-")" })")
        XCTAssertTrue(folded.closed, "HST is folded")
        XCTAssertFalse(listed.contains { $0.name?.contains("M31") == true }, "nothing of it shows while folded")

        let opened = await state.setUIOpen(.init(target: "HST"), open: true)
        XCTAssertTrue(opened.done, "\(opened)")
        XCTAssertEqual(opened.kind, UIElementKind.disclosure.rawValue)
        XCTAssertTrue(opened.inside.contains { $0.name?.contains("M31") == true }, "\(opened.inside.map(\.name))")

        let closed = await state.setUIOpen(.init(target: "HST"), open: false)
        XCTAssertTrue(closed.done, "\(closed)")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(state.uiHintPresenter.snapshot().elements.contains { $0.name?.contains("M31") == true },
                       "folded again")
    }
}
