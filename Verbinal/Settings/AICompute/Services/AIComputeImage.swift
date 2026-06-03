// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Lightweight, non-isolated resolver for the AI-Remote-Compute image —
/// the image `run_code` launches as a `contributed` session.
///
/// Reads `UserDefaults.standard` directly so it's callable from the
/// non-isolated `RunCodeTool.plan` without an actor hop.
/// `AIComputeSettingsService` (MainActor) owns *writing* the same key;
/// this is the read-only counterpart. Empty ⇒ `run_code` disabled.
enum AIComputeImage {

    /// Kept in sync with `AIComputeSettingsService.keyImage`.
    static let imageDefaultsKey = "com.codebg.Verbinal.aiCompute.image"

    /// No built-in default: empty means "unset / `run_code` disabled".
    static let builtinImageID = ""

    /// Resolved image id: the UserDefaults override, else empty.
    /// `defaults` is injectable for tests; production reads `.standard`.
    static func resolvedImageID(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: imageDefaultsKey) ?? builtinImageID
    }

    /// True when an image is configured — i.e. `run_code` may launch.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        !resolvedImageID(defaults).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
