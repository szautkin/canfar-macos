// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Plan 44, live (the person: "we need connect mcp tools to show this items
/// and read them"): the Activity list, opened from the bar, is read like any
/// other presentation — each task and its Retry — so an assistant reads it
/// and points at it.
@MainActor
final class ActivityListOnScreenTests: XCTestCase {
    func testTheActivityListAndItsRetryAreRead() async throws {
        try await AXReadable.require()
        let registry = TaskRegistry()
        let failed = registry.begin(.storage, "Syncing with your storage", by: .app)
        failed.offerRetry(byAssistant: true) { _ in }
        failed.fail("Could not connect to the server. Verbinal tries again in 2 min.")

        let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: 700, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack { Spacer(); ActivityBar(registry: registry) }
            .frame(width: 700, height: 500).uiWindowPlace(.main))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "landing" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(500))
        let bar = try XCTUnwrap(source.snapshot().elements.first { $0.id == "activity.bar" }, "the bar")
        let opened = await source.open(bar)
        XCTAssertTrue(opened, "the list opens from the bar")
        try await Task.sleep(for: .milliseconds(800))

        let names = source.snapshot().elements.compactMap(\.name)
        XCTAssertTrue(names.contains("Retry"), "its Retry: \(names)")
        XCTAssertTrue(names.contains { $0.contains("tries again in 2 min") }, "and why it failed: \(names)")
    }
}
