// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// capture_view draws a window upright and within its size (plan 15 Q1).
@MainActor
final class WindowCaptureTests: XCTestCase {

    private func rgb(_ image: CGImage, _ u: Int, _ v: Int) -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -u, y: -(image.height - 1 - v), width: image.width, height: image.height))
        return pixel.prefix(3).map(Int.init)
    }

    func testAWindowIsDrawnUprightWithinItsSize() throws {
        let content = VStack(spacing: 0) { Color.red; Color.blue }.frame(width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: content)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let image = try XCTUnwrap(WindowCapture.image(of: try XCTUnwrap(window.contentView), maxSide: 200))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 150)
        let top = rgb(image, 100, 10), bottom = rgb(image, 100, 140)
        XCTAssertGreaterThan(top[0], 200, "red on top: \(top)")
        XCTAssertGreaterThan(bottom[2], 200, "blue below: \(bottom)")
    }
}
