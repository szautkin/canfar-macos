// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Where one of Research's files is: on this Mac, in the person's CANFAR
/// storage, or both (the person's request, 2026-10-09). A file moves
/// between them by their action, and always keeps one copy.
struct FilePlaces: Equatable, Sendable {
    var onMac: Bool
    var inStorage: Bool

    var isNowhere: Bool { !onMac && !inStorage }

    /// As the person reads it.
    var title: String {
        switch (onMac, inStorage) {
        case (true, true): String(localized: "On this Mac and in your storage")
        case (true, false): String(localized: "On this Mac only")
        case (false, true): String(localized: "In your storage only")
        case (false, false): String(localized: "Not downloaded")
        }
    }

    /// As an assistant is told it.
    var word: String {
        switch (onMac, inStorage) {
        case (true, true): "both"
        case (true, false): "mac"
        case (false, true): "storage"
        case (false, false): "none"
        }
    }
}
