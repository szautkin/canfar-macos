// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Today's date: 2026-05-02.

import Foundation

/// One row in the Canfar Images dashboard widget. Bundles the
/// `ParsedImage` from the launch catalogue with whatever Verbinal
/// has learned about it so the row card can render uniformly:
///
///   * `manifest` non-nil → discovered, show OS + package count
///   * `failureMessage` non-nil → last probe failed, show the
///     reason so the user knows whether to retry
///   * neither → never inspected; "Inspect" button kicks one off
///
/// `isUserDefault` and `isRecentlyLaunched` drive the Default and
/// Popular tab inclusions.
struct CanfarImageRow: Identifiable, Equatable, Sendable {
    let image: ParsedImage
    let manifest: ImageManifest?
    let failureMessage: String?
    let isUserDefault: Bool
    let isRecentlyLaunched: Bool

    var id: String { image.id }

    /// Total package count across every section of the manifest —
    /// the headline number rendered on a discovered row.
    var packageCount: Int {
        guard let m = manifest else { return 0 }
        return m.dpkgPackages.count + m.rpmPackages.count + m.apkPackages.count
            + m.pythonPackages.count + m.rPackages.count
    }

    /// One of: `discovered`, `failed`, `unknown`. Drives the row's
    /// trailing-edge status icon.
    var status: Status {
        if manifest != nil { return .discovered }
        if failureMessage != nil { return .failed }
        return .unknown
    }

    enum Status: Sendable, Equatable {
        case discovered
        case failed
        case unknown
    }

    static func == (lhs: CanfarImageRow, rhs: CanfarImageRow) -> Bool {
        lhs.image.id == rhs.image.id &&
        lhs.manifest == rhs.manifest &&
        lhs.failureMessage == rhs.failureMessage &&
        lhs.isUserDefault == rhs.isUserDefault &&
        lhs.isRecentlyLaunched == rhs.isRecentlyLaunched
    }
}

/// Tabs the widget renders. Stable string ids land in UserDefaults
/// for "remember last selection" (deferred); also let tests assert
/// without depending on enum-ordering.
enum CanfarImagesTab: String, CaseIterable, Identifiable, Sendable {
    case `default` = "default"
    case popular = "popular"
    case notebook = "notebook"
    case desktop = "desktop"
    case carta = "carta"
    case firefly = "firefly"
    case contributed = "contributed"
    case headless = "headless"

    var id: String { rawValue }

    /// Title shown in the segmented picker.
    var title: String {
        switch self {
        case .default:     return "Default"
        case .popular:     return "Popular"
        case .notebook:    return "Notebook"
        case .desktop:     return "Desktop"
        case .carta:       return "CARTA"
        case .firefly:     return "Firefly"
        case .contributed: return "Contributed"
        case .headless:    return "Headless"
        }
    }

    /// Skaha session-type key for the type tabs. `nil` for
    /// `default` / `popular` (those use cross-type heuristics).
    var sessionTypeKey: String? {
        switch self {
        case .default, .popular:    return nil
        case .notebook:             return "notebook"
        case .desktop:              return "desktop"
        case .carta:                return "carta"
        case .firefly:              return "firefly"
        case .contributed:          return "contributed"
        case .headless:             return "headless"
        }
    }
}
