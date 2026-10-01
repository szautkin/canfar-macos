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
            .environment(UIPointerRegistry())
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
        _ = presenter.snapshot()
        try await Task.sleep(for: .milliseconds(400))
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
