// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import CryptoKit

/// Single source of truth for the SHA-256 hex used to derive probe/inspector
/// script-hash filenames. Previously duplicated byte-for-byte in
/// ProbeScript and InspectorScript (with an unreachable, incorrect
/// `String(hashValue)` `#else` fallback). CryptoKit ships on every Apple
/// platform this app targets, so there is no non-CryptoKit path.
enum ImageProbeScriptHash {
    /// Lowercase hex SHA-256 of `string`'s UTF-8 bytes.
    static func sha256Hex(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
