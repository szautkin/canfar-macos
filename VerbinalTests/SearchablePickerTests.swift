// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// A choice from a long list: a menu while it is short; past that a panel
/// that searches, holds to its height and moves by the keys — and reads as
/// a pop-up to the pointing tools, its rows as items.
@MainActor
final class SearchablePickerTests: XCTestCase {

    private let images = ["astroml:24.07", "astroml:latest", "notebook:latest", "Café-reduce:1.0", "improc-notebook:latest"]

    func testAShortListIsAMenu() {
        XCTAssertTrue(SearchableChoice.usesMenu(count: 12))
        XCTAssertFalse(SearchableChoice.usesMenu(count: 13))
    }

    func testASearchFindsEveryWordInAnyCaseAndAccent() {
        XCTAssertEqual(SearchableChoice.matches(images, query: "", label: { $0 }), images)
        XCTAssertEqual(SearchableChoice.matches(images, query: "NOTEBOOK", label: { $0 }), ["notebook:latest", "improc-notebook:latest"])
        XCTAssertEqual(SearchableChoice.matches(images, query: "latest astro", label: { $0 }), ["astroml:latest"], "every word")
        XCTAssertEqual(SearchableChoice.matches(images, query: "cafe", label: { $0 }), ["Café-reduce:1.0"], "with or without accents")
        XCTAssertTrue(SearchableChoice.matches(images, query: "fits", label: { $0 }).isEmpty)
    }

    func testTheKeysMoveWithinWhatMatches() {
        XCTAssertEqual(SearchableChoice.moved(nil, by: 1, in: images), images.first)
        XCTAssertEqual(SearchableChoice.moved(nil, by: -1, in: images), images.last)
        XCTAssertEqual(SearchableChoice.moved("astroml:latest", by: 1, in: images), "notebook:latest")
        XCTAssertEqual(SearchableChoice.moved(images.last, by: 1, in: images), images.last, "held at the end")
        XCTAssertEqual(SearchableChoice.moved(images.first, by: -1, in: images), images.first, "and at the start")
        XCTAssertNil(SearchableChoice.moved("x", by: 1, in: [String]()))
    }

    /// open_ui opens the panel, select_ui chooses a row in it — and the
    /// choice is made, the panel gone.
    func testTheToolsOpenItAndChooseInIt() async throws {
        try await AXReadable.require()
        final class Choice: ObservableObject { @Published var image = "astroml:24.07" }
        struct Long: View {
            @ObservedObject var choice: Choice
            let options = (0..<40).map { "image-\($0):latest" } + ["astroml:24.07"]
            var body: some View {
                SearchablePicker(title: "Container Image", selection: $choice.image, options: options, label: { $0 })
                    .padding(20).frame(width: 520, height: 480, alignment: .top).uiWindowPlace(.main)
            }
        }
        let choice = Choice()
        let window = NSWindow(contentRect: NSRect(x: 240, y: 200, width: 520, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Long(choice: choice))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let presenter = UIHintPresenter(store: UIHintStore(),
                                        source: AXElementSource(screenName: { _, _, _ in "picker" }),
                                        screenSignature: { "picker" })
        await presenter.ready()
        try await Task.sleep(for: .milliseconds(300))

        let picker = try XCTUnwrap(presenter.snapshot().elements.first { $0.name == "Container Image" })
        XCTAssertEqual(picker.kind, .popUp, "a pop-up to the tools")
        XCTAssertTrue(picker.closed)
        let opened = await presenter.setOpen(picker, true)
        XCTAssertTrue(opened.done)
        try await Task.sleep(for: .milliseconds(300))
        let now = presenter.snapshot()
        XCTAssertEqual(now.elements.first { $0.name == "Container Image" }?.closed, false, "open")
        XCTAssertNotNil(now.elements.first { $0.name == "Search" && $0.kind == .textField })
        let rows = now.elements.filter { $0.kind == .item }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertLessThanOrEqual(rows.count, SearchableChoice.visibleRows + 1, "held to its height")

        let pick = try XCTUnwrap(rows.first { $0.name == "image-3:latest" } ?? rows.first)
        let chosen = await presenter.select(pick)
        XCTAssertTrue(chosen.selected)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(choice.image, pick.name)
        XCTAssertNil(presenter.snapshot().elements.first { $0.name == "Search" && $0.kind == .textField },
                     "the panel closes on a choice")
    }
}
