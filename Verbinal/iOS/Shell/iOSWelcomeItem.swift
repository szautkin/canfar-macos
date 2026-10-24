// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A row of the welcome card (plan 50), as data: what Verbinal does without
/// an account first, then what an account adds. A new row is one entry here;
/// the card's view does not change.
struct iOSWelcomeItem: Identifiable, Sendable {
    let id: String
    let symbol: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    /// What a CANFAR account adds; shown under its own heading.
    let needsAccount: Bool

    static let all: [iOSWelcomeItem] = [
        iOSWelcomeItem(id: "fits", symbol: "photo", title: "View and verify FITS",
                       detail: "Zoom, sky coordinates and checksums; share a picture or the file.", needsAccount: false),
        iOSWelcomeItem(id: "cube", symbol: "cube", title: "Explore spectral cubes",
                       detail: "Step through the channels, read a spectrum, see a moment map.", needsAccount: false),
        iOSWelcomeItem(id: "files", symbol: "folder", title: "Your files, on this device",
                       detail: "Open them from Files, Mail or AirDrop; keep them and share them.", needsAccount: false),
        iOSWelcomeItem(id: "samples", symbol: "sparkles", title: "Try it now",
                       detail: "Two samples under Open: M31 from Hubble, GN-z11 from Webb.", needsAccount: false),
        iOSWelcomeItem(id: "account", symbol: "person.crop.circle", title: "Portal and Compute",
                       detail: "Your CANFAR sessions, your code and your storage, once you sign in.", needsAccount: true),
    ]

    /// The rows without an account, or the ones an account adds.
    static func rows(needingAccount: Bool) -> [iOSWelcomeItem] {
        all.filter { $0.needsAccount == needingAccount }
    }
}
