// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// `capture_view` shows what is on screen, text on materials included (plan
/// 19 C1, QA N16: the Portal header and the Cube side panel came out as
/// grey bars).
@MainActor
final class WindowCaptureTests: XCTestCase {

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 420, height: 160), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VStack {
            GroupBox { Text("Batch Jobs 0 running · 0 pending") }
            Text("Plain text").padding().background(.regularMaterial)
        }.padding().frame(width: 420, height: 160))
        return window
    }

    func testAWindowOnScreenIsTakenAsComposited() async throws {
        let window = window()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        guard let image = WindowCapture.composited(window, maxSide: 400) else {
            throw XCTSkip("no window server picture here (headless)")
        }
        XCTAssertLessThanOrEqual(max(image.width, image.height), 400)
        let hidden = self.window()
        XCTAssertNil(WindowCapture.composited(hidden, maxSide: 400), "not on screen: the layers are drawn instead")
        XCTAssertTrue(WindowCapture.shown(window) === window)
    }
}
