// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Result from the CADC target name resolver.
struct ResolverResult {
    let target: String
    let service: String
    let coordsRA: String
    let coordsDec: String
    var coordsys: String?
    var objectType: String?
    var morphologyType: String?
}
