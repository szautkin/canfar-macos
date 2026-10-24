// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One-shot bookkeeping for the first-run Welcome card, on the Mac and on
/// iPhone and iPad alike (plan 50); the cards differ. Mirrors
/// `LegalAgreementService`'s versioned-acceptance pattern: store the Welcome
/// version the person last saw; bump `currentVersion` to show the card again
/// (e.g. after a release that changes what the app does).
enum WelcomePreferences {
    /// Bump to re-show the Welcome card to everyone on the next launch.
    static let currentVersion = 1
    static let seenVersionKey = "verbinal.welcome.seenVersion"

    /// Whether the card shows now: after the Terms, once per version, and
    /// never over another sheet (the single-sheet host shows one at a time).
    static func shouldShow(seenVersion: Int, termsAccepted: Bool, sheetUp: Bool) -> Bool {
        termsAccepted && seenVersion < currentVersion && !sheetUp
    }
}
