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
    /// The hand-tagged ids `ContentView` shows for `state`, read as an
    /// assistant reads them — once `id` is among them, or after five seconds
    /// without it.
    static func pointTargets(_ state: AppState, waitingFor id: String) async throws -> Set<String> {
        try await AXReadable.require()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().uiWindowPlace(.main).environment(state))
        window.orderFrontRegardless()
        defer { window.close() }
        let source = AXElementSource(screenName: { state.screenName(of: $0, parentScreen: $1, title: $2) })
        await source.ready()
        var ids: Set<String> = []
        for _ in 0..<25 {
            let snapshot = source.snapshot()
            let mine = snapshot.windows.first { $0.number == window.windowNumber }
            ids = Set((mine.map { snapshot.elements(in: $0.index) } ?? []).filter(\.stable).map(\.id))
            if ids.contains(id) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        return ids
    }
}
