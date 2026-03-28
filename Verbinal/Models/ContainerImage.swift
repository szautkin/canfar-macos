// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct RawImage: Codable {
    let id: String
    let types: [String]
}

struct ParsedImage: Identifiable, Hashable {
    let id: String
    var registry: String
    var project: String
    var name: String
    var version: String
    var label: String
    var types: [String]

    static func == (lhs: ParsedImage, rhs: ParsedImage) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
