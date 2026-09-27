// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// A mark's menu as SwiftUI buttons, for a row of the Marks list.
struct MarkMenuButtons: View {
    let mark: Mark
    let host: MarkCommandHost

    var body: some View {
        ForEach(MarkMenuItem.items(for: mark, host: host)) { item in
            if item.destructive { Divider() }
            Button(role: item.destructive ? .destructive : nil) {
                host.perform(item.command, on: mark)
            } label: {
                Label(item.title, systemImage: item.systemImage)
            }
            .disabled(!item.enabled)
            .help(item.disabledReason ?? "")
        }
    }
}

#if os(macOS)
import AppKit

extension MarkMenuItem {
    /// The same menu for the canvas, where the right-click lands in AppKit.
    @MainActor
    static func menu(for mark: Mark, host: MarkCommandHost) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(for: mark, host: host) {
            if item.destructive { menu.addItem(.separator()) }
            let entry = ClosureMenuItem(title: item.title) { host.perform(item.command, on: mark) }
            entry.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
            entry.isEnabled = item.enabled
            entry.toolTip = item.disabledReason
            menu.addItem(entry)
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}
#endif
