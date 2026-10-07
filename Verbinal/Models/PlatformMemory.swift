// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Memory as CANFAR reports it, read one way everywhere: a session card,
/// the Remote Compute screen, what a compute session differs by.
enum PlatformMemory {
    /// Memory as the platform reports it ("8G", "8Gi", "1.07G", "512M", or a
    /// bare "8.59"), in GB as the launch form and Settings count them; nil
    /// when unreadable. A bare number is decimal GB of a request made in
    /// GiB — 8 asked comes back 8.59, 9 as 9.66 — so it is turned back
    /// into the figure asked for (handout 31: a card said 10 GB for 9).
    static func gigabytes(_ allocated: String) -> Double? {
        let text = allocated.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        switch text.dropFirst(digits.count).trimmingCharacters(in: CharacterSet(charactersIn: "ib ")) {
        case "": return value / 1.073_741_824
        case "g": return value
        case "m": return value / 1024
        case "t": return value * 1024
        default: return nil
        }
    }
}
