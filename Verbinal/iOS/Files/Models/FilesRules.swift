// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The rules of the files on this device, in one place (plan 48): the
/// cache's cap and what is suggested for deletion.
enum FilesRules {
    /// The caps the person can choose for Downloads, in GB, and the default (D5).
    static let capChoices = [1, 2, 5, 10]
    static let defaultCapGB = 2
    static let capKey = "ios.files.downloadsCapGB"

    /// Downloads and received files not opened for this long are suggested.
    static let staleDays = 30

    /// The cap the person chose, else the default.
    static func capGB(_ defaults: UserDefaults = .standard) -> Int {
        let chosen = defaults.integer(forKey: capKey)
        return capChoices.contains(chosen) ? chosen : defaultCapGB
    }

    static func capBytes(_ defaults: UserDefaults = .standard) -> Int64 {
        Int64(capGB(defaults)) * 1024 * 1024 * 1024
    }

    /// What can go: downloads and received files not opened in `staleDays`.
    /// Kept files were kept on purpose and are never suggested.
    static func stale(_ files: [LocalFile], now: Date = Date()) -> [LocalFile] {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        return files.filter { $0.kind != .kept && $0.lastOpened < cutoff }
    }

    /// A name for a new folder in storage: not empty, no slash, not "." or "..".
    static func isValidName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// The bytes `files` take.
    static func bytes(_ files: [LocalFile]) -> Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}
