// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The menu behind the initials button (plan 48), as data: its sections in
/// order, each with its entries. A new entry is a case and a place here.
enum iOSMenuEntry: String, CaseIterable, Identifiable, Sendable {
    case onThisDevice, yourStorage
    case reminders, downloadsCap, aiCompute
    case help, about, terms
    case signOut

    var id: String { rawValue }

    enum Section: String, CaseIterable, Identifiable, Sendable {
        case files, settings, help, account
        var id: String { rawValue }
    }

    /// The menu, top to bottom.
    static let layout: [(section: Section, entries: [iOSMenuEntry])] = [
        (.files, [.onThisDevice, .yourStorage]),
        (.settings, [.reminders, .downloadsCap, .aiCompute]),
        (.help, [.help, .about, .terms]),
        (.account, [.signOut]),
    ]

    /// Verbinal's manual, online.
    static let helpURL = URL(string: "https://docs.verbinal.com/")!
}
