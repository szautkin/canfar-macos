// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What is on screen now: the windows front to back, and the elements in
/// each (plan 27).
struct UISnapshot: Equatable, Sendable {
    let windows: [UIWindowRef]
    let elements: [UIElement]
    /// Hand-tagged ids found more than once in one window: the first kept it.
    let duplicateIDs: [String]

    static let empty = UISnapshot(windows: [], elements: [], duplicateIDs: [])

    /// The window in front — a sheet over its window, Settings over the app.
    var front: UIWindowRef? { windows.first }

    func elements(in window: Int) -> [UIElement] { elements.filter { $0.window == window } }
}

/// Where the elements come from — the accessibility tree in the app, a fake
/// in tests. Everything that lists or points at the interface asks this,
/// and nothing else (plan 27).
@MainActor
protocol UIElementSource: AnyObject {
    func snapshot() -> UISnapshot
}
