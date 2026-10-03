// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Verbinal

/// Plan 27 O: hints drawn over a real window — placed, followed as it
/// scrolls, and taken down when its screen changes.
@MainActor
final class UIHintPresenterTests: XCTestCase {

    @Observable
    @MainActor
    final class Place { var screen = "sample" }

    private struct Sample: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Run Search") {}
                    Button("Reset") {}
                    Toggle("Public only", isOn: .constant(true))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<30) { i in Button("Item \(i)") {} }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
            }
            .padding(20)
            .frame(width: 700, height: 500, alignment: .topLeading)
            .uiWindowPlace(.main)
        }
    }

    private var window: NSWindow?
    private var presenter: UIHintPresenter?
    private let place = Place()

    override func tearDown() async throws {
        presenter?.store.clearAll()
        window?.close()
        window = nil
        presenter = nil
    }

    private func start() async throws -> UIHintPresenter {
        try await AXReadable.require()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Sample())
        window.makeKeyAndOrderFront(nil)
        self.window = window
        let place = place
        let presenter = UIHintPresenter(
            store: UIHintStore(),
            source: AXElementSource(screenName: { kind, _, _ in kind == .main ? place.screen : "other" }),
            screenSignature: { place.screen })
        self.presenter = presenter
        await presenter.ready()
        try await Task.sleep(for: .milliseconds(300))
        _ = presenter.snapshot()
        return presenter
    }

    private func element(_ presenter: UIHintPresenter, _ name: String) throws -> UIElement {
        try XCTUnwrap(presenter.lastSnapshot.elements.first { $0.name == name && $0.screen == place.screen }, name)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    private var panel: NSWindow? {
        window?.childWindows?.first { $0.identifier?.rawValue == PointableID.Window.hints.identifier }
    }

    func testHintsAreDrawnOverTheirWindowWithoutOverlapping() async throws {
        let presenter = try await start()
        let requests = try ["Run Search", "Reset", "Public only"].map {
            UIHintPresenter.Request(element: try element(presenter, $0), title: nil, text: "This is \($0).", style: .bubble)
        }
        presenter.show(requests, numbered: true, dim: false, seconds: nil, replace: true)
        try await settle()
        let panel = try XCTUnwrap(panel, "an overlay over the window")
        XCTAssertEqual(panel.frame, window?.frame)
        XCTAssertTrue(panel.ignoresMouseEvents, "clicks go through to the app")
        let scene = try XCTUnwrap(presenter.scene(on: try XCTUnwrap(window).windowNumber))
        XCTAssertEqual(scene.bubbles.count, 3)
        XCTAssertEqual(scene.bubbles.compactMap(\.number).sorted(), [1, 2, 3])
        for (i, a) in scene.bubbles.enumerated() {
            for b in scene.bubbles[(i + 1)...] { XCTAssertFalse(a.frame.intersects(b.frame)) }
            for ring in scene.rings { XCTAssertFalse(ring.frame.intersects(a.frame)) }
        }
        presenter.store.clearAll()
        try await settle()
        XCTAssertNil(self.panel, "gone with its hints")
    }

    /// A hint follows its element as the person scrolls; scrolled out of
    /// sight, it goes.
    func testAHintFollowsItsElementAsItScrolls() async throws {
        let presenter = try await start()
        let item = try element(presenter, "Item 3")
        presenter.show([.init(element: item, title: nil, text: nil, style: .ring)],
                       numbered: false, dim: false, seconds: nil, replace: true)
        try await settle()
        let before = try XCTUnwrap(presenter.store.hints.first).frame
        let scrollView = try XCTUnwrap(Self.scrollViews(in: try XCTUnwrap(window?.contentView)).first)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 40))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(300))
        let after = try XCTUnwrap(presenter.store.hints.first, "still in sight").frame
        XCTAssertEqual(after.minY, before.minY - 40, accuracy: 1)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(presenter.store.isEmpty, "scrolled out of sight")
    }

    /// A control scrolled out of sight is kept apart, and brought into view
    /// when a hint names it (plan 27 V).
    func testAnElementOutOfSightIsBroughtIntoView() async throws {
        let presenter = try await start()
        let away = try XCTUnwrap(presenter.lastSnapshot.outOfSight.first { $0.name == "Item 25" }, "kept, out of sight")
        XCTAssertFalse(presenter.lastSnapshot.elements.contains { $0.name == "Item 25" }, "not listed in sight")
        let found = await presenter.bringIntoView([away])
        let now = try XCTUnwrap(found[away.id], "found again")
        XCTAssertTrue(now.inSight)
        XCTAssertTrue(now.inSight)
        XCTAssertEqual(now.name, "Item 25")
        presenter.show([.init(element: now, title: nil, text: "Here it is.", style: .bubble)],
                       numbered: false, dim: false, seconds: nil, replace: true)
        XCTAssertEqual(presenter.store.hints.first?.id, now.id)
    }

    /// A form under a toolbar — as Settings is — scrolls beneath it: its
    /// scroll view is taller than its scroll area, and still found.
    func testAFormUnderAToolbarIsScrolledToo() async throws {
        try await AXReadable.require()
        let window = NSWindow(contentRect: NSRect(x: 220, y: 220, width: 600, height: 360),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "qa")
        window.toolbarStyle = .preference
        window.contentView = NSHostingView(rootView: Form {
            ForEach(0..<30) { i in Toggle("Setting \(i)", isOn: .constant(i.isMultiple(of: 2))) }
        }.formStyle(.grouped).uiWindowPlace(.main))
        window.orderFrontRegardless()
        defer { window.close() }
        let presenter = UIHintPresenter(store: UIHintStore(),
                                        source: AXElementSource(screenName: { _, _, _ in "form" }),
                                        screenSignature: { "form" })
        await presenter.ready()
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = presenter.snapshot()
        let away = try XCTUnwrap(snapshot.outOfSight.first { $0.name == "Setting 27" }, "kept, out of sight")
        let found = await presenter.bringIntoView([away])
        XCTAssertEqual(found[away.id]?.inSight, true, "scrolled into view")
    }

    @Observable
    @MainActor
    final class Chosen {
        var row: Int?
        var item: String?
        var pressed = false
    }

    /// select_ui selects as a click does: a list's row by its selected state,
    /// an item by its own action — and never presses a button.
    func testSelectingARowAnItemAndNeverAButton() async throws {
        try await AXReadable.require()
        let chosen = Chosen()
        struct Lists: View {
            @Bindable var chosen: Chosen
            var body: some View {
                VStack {
                    List(0..<20, id: \.self, selection: $chosen.row) { Text("Entry \($0)") }.frame(height: 160)
                    HStack {
                        Text("Selectable").padding().pointableItem("selectable item") { chosen.item = "selectable item" }
                        Text("Whole").padding().pointableItem("whole item", whole: true) { chosen.item = "whole item" }
                        Text("Card").padding().pointableItem("card only")
                        Button("Delete everything") { chosen.pressed = true }
                    }
                }
                .padding().frame(width: 600, height: 400).uiWindowPlace(.main)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Lists(chosen: chosen))
        window.orderFrontRegardless()
        defer { window.close() }
        let presenter = UIHintPresenter(store: UIHintStore(),
                                        source: AXElementSource(screenName: { _, _, _ in "lists" }),
                                        screenSignature: { "lists" })
        await presenter.ready()
        try await Task.sleep(for: .milliseconds(300))
        func element(_ name: String) throws -> UIElement {
            let snapshot = presenter.snapshot()
            return try XCTUnwrap((snapshot.elements + snapshot.outOfSight).first { $0.name == name }, name)
        }
        let row = try element("Entry 3")
        XCTAssertEqual(row.kind, .row)
        let selectedRow = await presenter.select(row).selected
        XCTAssertTrue(selectedRow)
        XCTAssertEqual(chosen.row, 3)

        let far = try element("Entry 17")
        let selectedFar = await presenter.select(far)
        XCTAssertTrue(selectedFar.selected, "brought into view, then selected")
        XCTAssertEqual(chosen.row, 17)

        let selectable = try element("selectable item")
        let selectedItem = await presenter.select(selectable).selected
        XCTAssertTrue(selectedItem)
        XCTAssertEqual(chosen.item, "selectable item")

        // One element with its action reads as a button: still an item, still selected.
        let whole = try element("whole item")
        XCTAssertEqual(whole.kind, .item)
        let selectedWhole = await presenter.select(whole).selected
        XCTAssertTrue(selectedWhole)
        XCTAssertEqual(chosen.item, "whole item")

        let card = try element("card only")
        let selectedCard = await presenter.select(card).selected
        XCTAssertFalse(selectedCard, "a card that does not select")

        let button = try element("Delete everything")
        let pressed = await presenter.select(button).selected
        XCTAssertFalse(pressed)
        XCTAssertFalse(chosen.pressed, "select never presses a button")
    }

    @Observable
    @MainActor
    final class Shown {
        var tab = "Running"
        var resources = "Flexible"
        var pressed = false
    }

    /// select_ui selects a tab drawn as buttons and a segment, as a click
    /// does — view state — and still never presses a button (plan 30 T5).
    func testSelectingATabAndASegmentAndNeverAButton() async throws {
        try await AXReadable.require()
        let shown = Shown()
        struct Tabs: View {
            @Bindable var shown: Shown
            var body: some View {
                VStack(alignment: .leading) {
                    HStack {
                        ForEach(["Running", "History"], id: \.self) { tab in
                            Button(tab) { shown.tab = tab }.buttonStyle(.plain).pointableTab(selected: shown.tab == tab)
                        }
                    }
                    Picker("Resources", selection: $shown.resources) {
                        Text("Flexible").tag("Flexible")
                        Text("Fixed").tag("Fixed")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button("Launch") { shown.pressed = true }
                }
                .padding().frame(width: 500, height: 300, alignment: .topLeading).uiWindowPlace(.main)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Tabs(shown: shown))
        window.orderFrontRegardless()
        defer { window.close() }
        let presenter = UIHintPresenter(store: UIHintStore(),
                                        source: AXElementSource(screenName: { _, _, _ in "tabs" }),
                                        screenSignature: { "tabs" })
        await presenter.ready()
        try await Task.sleep(for: .milliseconds(300))
        func element(_ name: String) throws -> UIElement {
            try XCTUnwrap(presenter.snapshot().elements.first { $0.name == name }, name)
        }

        let history = try element("History")
        XCTAssertEqual(history.kind, .tab)
        let selectedTab = await presenter.select(history).selected
        XCTAssertTrue(selectedTab)
        XCTAssertEqual(shown.tab, "History")

        let fixed = try element("Fixed")
        XCTAssertTrue(fixed.kind.selects, "\(fixed.kind)")
        let selectedSegment = await presenter.select(fixed).selected
        XCTAssertTrue(selectedSegment)
        XCTAssertEqual(shown.resources, "Fixed")

        let launch = try element("Launch")
        XCTAssertFalse(launch.kind.selects)
        let pressed = await presenter.select(launch).selected
        XCTAssertFalse(pressed)
        XCTAssertFalse(shown.pressed, "select never presses a button")
    }

    /// open_ui's work: a folded section opens — and what was behind it
    /// appears — and closes again; a menu opens without the call waiting on
    /// the person, and closes (plan 27 C).
    func testASectionAndAMenuOpenAndClose() async throws {
        try await AXReadable.require()
        struct Closed: View {
            @State private var open = false
            @State private var mode = 1
            var body: some View {
                VStack(alignment: .leading) {
                    DisclosureGroup("Advanced", isExpanded: $open) { Button("Hidden inside") {} }
                    Picker("Mode", selection: $mode) { Text("One").tag(1); Text("Two").tag(2) }.pickerStyle(.menu)
                }
                .padding().frame(width: 500, height: 300).uiWindowPlace(.main)
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Closed())
        window.orderFrontRegardless()
        defer { window.close() }
        let presenter = UIHintPresenter(store: UIHintStore(),
                                        source: AXElementSource(screenName: { _, _, _ in "closed" }),
                                        screenSignature: { "closed" })
        await presenter.ready()
        try await Task.sleep(for: .milliseconds(300))
        let section = try XCTUnwrap(presenter.snapshot().elements.first { $0.name == "Advanced" })
        XCTAssertTrue(section.closed)
        let opened = await presenter.setOpen(section, true)
        XCTAssertTrue(opened.done)
        XCTAssertEqual(opened.appeared.map(\.name), ["Hidden inside"], "what was behind it — and only that")
        let reopened = try XCTUnwrap(presenter.lastSnapshot.elements.first { $0.name == "Advanced" })
        XCTAssertFalse(reopened.closed)
        let shut = await presenter.setOpen(reopened, false)
        XCTAssertTrue(shut.done)
        XCTAssertFalse(presenter.lastSnapshot.elements.contains { $0.name == "Hidden inside" })

        let menu = try XCTUnwrap(presenter.snapshot().elements.first { $0.kind == .popUp })
        let shown = await presenter.setOpen(menu, true)
        XCTAssertTrue(shown.done, "opened without waiting on the person")
        let open = try XCTUnwrap(presenter.lastSnapshot.elements.first { $0.handle == presenter.lastSnapshot.elements.first { $0.kind == .popUp }?.handle })
        XCTAssertTrue(presenter.lastSnapshot.elements.contains { $0.kind == .menuItem } || !open.closed, "its choices are on screen")
        let dismissed = await presenter.setOpen(open, false)
        XCTAssertTrue(dismissed.done)
    }

    func testHintsGoWhenTheirScreenChanges() async throws {
        let presenter = try await start()
        presenter.show([.init(element: try element(presenter, "Reset"), title: nil, text: "Clears the form.", style: .bubble)],
                       numbered: false, dim: false, seconds: nil, replace: true)
        try await settle()
        XCTAssertFalse(presenter.store.isEmpty)
        place.screen = "elsewhere"
        try await settle()
        XCTAssertTrue(presenter.store.isEmpty)
    }

    /// Hints are not marks: taking hints down leaves the marks kept with a
    /// file, and clearing marks leaves the hints.
    func testHintsAndMarksNeverTouchEachOther() async throws {
        let presenter = try await start()
        let marks = MarkStore(persistence: nil)
        let target = MarkStore.Target(file: URL(fileURLWithPath: "/data/m31.fits"), hdu: 0)
        try marks.add(Mark(id: marks.newID(on: target), kind: .circle, anchor: .init(space: .imagePixel, x: 10, y: 10),
                           extent: .square(5), author: .user, createdAt: Date()), to: target)
        presenter.show([.init(element: try element(presenter, "Reset"), title: nil, text: "Clears.", style: .bubble)],
                       numbered: false, dim: false, seconds: nil, replace: true)
        presenter.store.clearAll()
        XCTAssertEqual(marks.marks(on: target).count, 1)
        presenter.show([.init(element: try element(presenter, "Reset"), title: nil, text: "Clears.", style: .bubble)],
                       numbered: false, dim: false, seconds: nil, replace: true)
        _ = marks.clear([target])
        XCTAssertTrue(marks.marks(on: target).isEmpty)
        XCTAssertEqual(presenter.store.hints.count, 1)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
