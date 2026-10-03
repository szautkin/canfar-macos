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

    /// Plan 30 C: the hints over a window are in its picture, as the person sees them.
    func testTheHintsOverAWindowAreInItsPicture() async throws {
        let window = window()
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let hints = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        hints.identifier = NSUserInterfaceItemIdentifier(PointableID.Window.hints.identifier)
        hints.isOpaque = false
        hints.backgroundColor = .clear
        hints.isReleasedWhenClosed = false
        hints.contentView = NSHostingView(rootView: Color.red.frame(width: 120, height: 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        try await Task.sleep(for: .milliseconds(300))
        guard let plain = WindowCapture.composited(window, maxSide: 400) else {
            throw XCTSkip("no window server picture here (headless)")
        }
        guard !isClear(atCentreOf: plain) else {
            throw XCTSkip("the window server's pictures are blank (is the screen locked?)")
        }
        window.addChildWindow(hints, ordered: .above)
        hints.orderFront(nil)
        defer { hints.close() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(WindowCapture.hintPanels(over: window), [hints])
        let hinted = try XCTUnwrap(WindowCapture.composited(window, maxSide: 400))
        XCTAssertFalse(isRed(atCentreOf: plain), "the window alone")
        XCTAssertTrue(isRed(atCentreOf: hinted), "the hint drawn over it")
    }

    private func isRed(atCentreOf image: CGImage) -> Bool {
        let pixel = centre(of: image)
        return pixel[0] > 200 && pixel[1] < 80 && pixel[2] < 80
    }

    private func isClear(atCentreOf image: CGImage) -> Bool { centre(of: image) == [0, 0, 0, 0] }

    /// The centre pixel, RGBA.
    private func centre(of image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let one = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1))
        else { return pixel }
        context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }
}
