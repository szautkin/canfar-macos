// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct BreadcrumbSegment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String

    /// Build breadcrumb segments from a relative path.
    /// e.g. "folder/sub/deep" → [("Home", ""), ("folder", "folder"), ("sub", "folder/sub"), ("deep", "folder/sub/deep")]
    static func fromPath(_ path: String) -> [BreadcrumbSegment] {
        var segments = [BreadcrumbSegment(name: "Home", path: "")]
        guard !path.isEmpty else { return segments }

        let parts = path.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            let segmentPath = parts[0...i].joined(separator: "/")
            segments.append(BreadcrumbSegment(name: part, path: segmentPath))
        }
        return segments
    }
}
