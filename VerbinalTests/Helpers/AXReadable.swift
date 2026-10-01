// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// The tests that read the app's windows as an assistant does need macOS's
/// accessibility service to answer for this process. When it does not — it
/// hands back the application for every window, as while the screen is
/// locked, or on a runner with no screen session — they are skipped, saying why,
/// rather than failing for a reason that is not the code's.
@MainActor
enum AXReadable {
    static func require() async throws {
        let probe = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 200, height: 120),
                             styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        probe.contentView = NSHostingView(rootView: Text("probe"))
        probe.orderFrontRegardless()
        defer { probe.close() }
        try await Task.sleep(for: .milliseconds(150))
        if !AXElementSource.readable {
            throw XCTSkip("the accessibility service is not answering for this process's windows (is the screen locked?)")
        }
    }
}
