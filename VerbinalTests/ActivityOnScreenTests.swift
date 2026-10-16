// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// On screen (plan 40 step 2): the activity list shows how far a task has
/// got, and Pause or Resume on one that can wait.
@MainActor
final class ActivityOnScreenTests: XCTestCase {
    func testTheListShowsTheCountAndPauseThenResume() async throws {
        try await AXReadable.require()
        let registry = TaskRegistry()
        let sync = registry.begin(.storage, "Syncing with your storage", by: .app,
                                  pausing: .init(pause: { _ in }, resume: { _ in }))
        sync.stage("Image package lists")
        sync.count(120, of: 288)

        let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 460, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ActivityList(registry: registry).uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "activity" })
        await source.ready()

        func names() async throws -> [String] {
            try await Task.sleep(for: .milliseconds(1500))  // the list redraws each second
            let snapshot = source.snapshot()
            let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
            return snapshot.elements(in: ref.index).compactMap(\.name)
        }
        var shown = try await names()
        XCTAssertTrue(shown.contains("Pause"), "\(shown)")
        XCTAssertTrue(shown.contains { $0.contains("Image package lists, 120 of 288") }, "\(shown)")

        XCTAssertNil(registry.pause(sync.id, by: .person))
        shown = try await names()
        XCTAssertTrue(shown.contains("Resume"), "\(shown)")
        XCTAssertTrue(shown.contains { $0.contains("Paused by you") }, "\(shown)")
    }
}
