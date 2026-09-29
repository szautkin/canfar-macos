// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
@testable import Verbinal

/// The app's window content, shown for real, to see what it offers.
@MainActor
enum HostedContentView {
    /// The pointable targets `ContentView` registers for `state`, once
    /// `id` is among them — or after five seconds without it.
    static func pointTargets(_ state: AppState, waitingFor id: String) async throws -> Set<String> {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView()
            .environment(state)
            .environment(state.uiPointer))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<250 where state.uiPointer.targets[id] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        return Set(state.uiPointer.targets.keys)
    }
}
