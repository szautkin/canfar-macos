// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The menu behind the initials button (plan 48), as data: its sections in
/// order, each with its entries, and which need the person's account (plan
/// 49). A new entry is a case and a place here.
enum iOSMenuEntry: String, CaseIterable, Identifiable, Sendable {
    case onThisDevice, yourStorage
    case reminders, downloadsCap, language, aiCompute
    case help, welcome, about, terms
    case signIn, signOut

    var id: String { rawValue }

    enum Section: String, CaseIterable, Identifiable, Sendable {
        case files, settings, help, account
        var id: String { rawValue }
    }

    /// The menu, top to bottom. Signed in, Sign Out comes last; signed out,
    /// Sign In comes first, as Settings puts "Sign in to your iPhone".
    static func layout(signedIn: Bool) -> [(section: Section, entries: [iOSMenuEntry])] {
        let places: [(section: Section, entries: [iOSMenuEntry])] = [
            (.files, [.onThisDevice, .yourStorage]),
            (.settings, [.reminders, .downloadsCap, .language, .aiCompute]),
            (.help, [.help, .welcome, .about, .terms]),
        ]
        return signedIn ? places + [(.account, [.signOut])] : [(.account, [.signIn])] + places
    }

    /// Locked while signed out: these are the person's CANFAR account.
    var needsAccount: Bool {
        switch self {
        case .yourStorage, .reminders, .aiCompute, .signOut: return true
        case .onThisDevice, .downloadsCap, .language, .help, .welcome, .about, .terms, .signIn: return false
        }
    }

    /// Verbinal's manual, online.
    static let helpURL = URL(string: "https://docs.verbinal.com/")!
}
