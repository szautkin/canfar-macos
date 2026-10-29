// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
@testable import Verbinal

/// For looking at: a window as drawn, saved as `name`.png to the folder the
/// environment names (VERBINAL_TEST_CAPTURES), when it names one. One way
/// to take the picture, the app's own (`WindowCapture`).
@MainActor
enum TestCaptures {
    static func save(_ window: NSWindow, as name: String) async {
        guard let folder = ProcessInfo.processInfo.environment["VERBINAL_TEST_CAPTURES"],
              let image = await WindowCapture.composited(window, maxSide: .max),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
