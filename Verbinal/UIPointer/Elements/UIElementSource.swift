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
    /// Why nothing could be read, when the app's windows are up but macOS's
    /// accessibility service is not answering for them.
    var problem: String? = nil
    /// What is scrolled out of sight inside a scroll area: not listed unless
    /// asked, and brought into view when a hint names it.
    var outOfSight: [UIElement] = []

    static let empty = UISnapshot(windows: [], elements: [], duplicateIDs: [])

    /// What an assistant is told when the screen cannot be read.
    static let unreadable = "macOS's accessibility service is not answering for Verbinal's windows right now — as while the screen is locked, or just after a display change. Try again when the person is at the screen; if it lasts, quit and reopen Verbinal."

    /// What an assistant is told when none of Verbinal's windows shows.
    static let notShowing = "No Verbinal window is showing: its windows are closed or minimized, the app is hidden, or they are on another desktop. open_ui `Main Window` brings it back when it is closed, minimized or hidden; on another desktop, ask the person to bring it to the front, then try again."

    /// Why a read found no window: the service not answering for windows
    /// that are up, or no window showing at all. Nil when it found some.
    static func problem(windowsRead: Int, unanswered: Bool, anyUp: Bool, anyShowing: Bool) -> String? {
        guard windowsRead == 0 else { return nil }
        if unanswered && anyUp { return unreadable }
        return anyShowing ? nil : notShowing
    }

    /// The window in front — a sheet over its window, Settings over the app.
    var front: UIWindowRef? { windows.first }

    func elements(in window: Int) -> [UIElement] { elements.filter { $0.window == window } }
    func outOfSight(in window: Int) -> [UIElement] { outOfSight.filter { $0.window == window } }
}

/// Where the elements come from — the accessibility tree in the app, a fake
/// in tests. Everything that lists or points at the interface asks this,
/// and nothing else (plan 27).
@MainActor
protocol UIElementSource: AnyObject {
    func snapshot() -> UISnapshot
}
