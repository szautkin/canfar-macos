// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Two small public files to try the viewers with, signed in or not (plan 49
/// D4): cut down from the person's showcase-cubes-2026-10, each with its
/// credit in its header (COMMENT) and what was done to it (HISTORY).
struct iOSSample: Identifiable, Sendable {
    /// The file's name in the app's bundle (Verbinal/iOS/Samples).
    let resource: String
    let title: LocalizedStringResource
    /// Who made the observation, as its header credits it.
    let credit: String
    let systemImage: String

    var id: String { resource }

    var url: URL? { Bundle.main.url(forResource: resource, withExtension: nil) }

    static let all = [
        iOSSample(resource: "M31-Hubble-WFPC-1991.fits", title: "M31, the Andromeda Galaxy",
                  credit: "NASA/ESA Hubble Space Telescope · WF/PC, 1991", systemImage: "photo"),
        iOSSample(resource: "GN-z11-JWST-NIRSpec.fits", title: "GN-z11, a Galaxy at Redshift 10.6",
                  credit: "NASA/ESA/CSA JWST · NIRSpec IFU, program 4528 (PI K. Isaak)", systemImage: "cube"),
    ]
}
