// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

extension Image {
    /// The agent robot glyph — a custom SF Symbol drawn to match the
    /// Windows client's Segoe Fluent Icons Robot (U+E99A), so agent
    /// activity looks identical across platforms. Behaves like any
    /// system symbol (template rendering, font sizing, symbol effects).
    static var agentRobot: Image { Image("robot") }

    /// Resolve `name` as a system SF Symbol when it exists, falling back
    /// to a custom symbol in the asset catalog. Lets String-typed icon
    /// parameters (LandingTile, FeatureRow, pillar) accept the custom
    /// `robot` glyph without changing their signatures.
    init(symbol name: String) {
        #if os(macOS)
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            self.init(systemName: name)
        } else {
            self.init(name)
        }
        #else
        if UIImage(systemName: name) != nil {
            self.init(systemName: name)
        } else {
            self.init(name)
        }
        #endif
    }
}
