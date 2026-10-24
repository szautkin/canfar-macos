// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a place may show (plan 49): the place itself, or why not yet. The
/// places do not ask about the sign-in; the shell asks this, once.
enum iOSPlaceAccess: Equatable, Sendable {
    /// Needs no account, or the person is signed in.
    case open
    /// A stored session is being checked: no lock flashes meanwhile.
    case checking
    /// A stored session waits for the network to be checked.
    case waitingForNetwork
    /// Signed out: what the place is for, and Sign In.
    case locked

    static func of(needsAccount: Bool, signedIn: Bool, checking: Bool, waitingForNetwork: Bool) -> iOSPlaceAccess {
        guard needsAccount, !signedIn else { return .open }
        if waitingForNetwork { return .waitingForNetwork }
        return checking ? .checking : .locked
    }

    var isLocked: Bool { self != .open }
}
