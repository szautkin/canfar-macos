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

    /// Kept in sync with `AIComputeSettingsService.keyCores`/`keyRam`.
    static let coresDefaultsKey = "com.codebg.Verbinal.aiCompute.cores"
    static let ramDefaultsKey   = "com.codebg.Verbinal.aiCompute.ram"

    /// Built-in fallback size when the user hasn't picked one — the
    /// smallest, fastest-to-schedule instance.
    static let builtinCores = 1
    static let builtinRam   = 1

    /// No built-in default: empty means "unset / `run_code` disabled".
    static let builtinImageID = ""

    /// Resolved image id: the UserDefaults override, else empty.
    /// `defaults` is injectable for tests; production reads `.standard`.
    static func resolvedImageID(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: imageDefaultsKey) ?? builtinImageID
    }

    /// Resolved default instance size for the `run_code` lazy launch and
    /// the `start_compute` fallback: the UserDefaults override (>= 1),
    /// else the built-in (1, 1). Mirrors `resolvedImageID` so the MCP
    /// tools resolve resources without an `AppState`/MainActor hop.
    /// `defaults` is injectable for tests; production reads `.standard`.
    static func resolvedResources(_ defaults: UserDefaults = .standard) -> (cores: Int, ram: Int) {
        let cores = (defaults.object(forKey: coresDefaultsKey) as? Int).flatMap { $0 >= 1 ? $0 : nil } ?? builtinCores
        let ram   = (defaults.object(forKey: ramDefaultsKey)   as? Int).flatMap { $0 >= 1 ? $0 : nil } ?? builtinRam
        return (cores, ram)
    }

    /// True when an image is configured — i.e. `run_code` may launch.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        !resolvedImageID(defaults).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
