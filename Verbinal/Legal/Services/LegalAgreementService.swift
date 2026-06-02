// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Tracks whether the user has accepted the current Terms of Use.
///
/// Acceptance is versioned: bump ``currentVersion`` whenever ``LegalText`` changes
/// materially and every user is re-prompted on next launch. The accepted version and
/// timestamp are persisted in `UserDefaults` (cheap, fixed-size, survives reinstall via
/// backup) so the first-launch gate only appears when acceptance is missing or stale.
@MainActor
@Observable
final class LegalAgreementService {

    /// Bump this when the Terms text changes in a way that requires re-acceptance.
    /// Keep in lockstep with ``LegalText/version``.
    static let currentVersion = LegalText.version

    private let defaults: UserDefaults
    private let acceptedVersionKey = "legal.acceptedTermsVersion"
    private let acceptedAtKey = "legal.acceptedTermsAt"

    private(set) var acceptedVersion: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.acceptedVersion = defaults.integer(forKey: acceptedVersionKey)
    }

    /// True once the user has accepted a version >= the current Terms version.
    var hasAcceptedCurrent: Bool {
        acceptedVersion >= Self.currentVersion
    }

    /// When the current Terms were accepted (nil if never / stale).
    var acceptedAt: Date? {
        guard hasAcceptedCurrent else { return nil }
        let t = defaults.double(forKey: acceptedAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Record acceptance of the current Terms version.
    func accept(now: Date = Date()) {
        acceptedVersion = Self.currentVersion
        defaults.set(Self.currentVersion, forKey: acceptedVersionKey)
        defaults.set(now.timeIntervalSince1970, forKey: acceptedAtKey)
    }

    /// Clear acceptance (used by tests; could back a "review terms again" debug action).
    func reset() {
        acceptedVersion = 0
        defaults.removeObject(forKey: acceptedVersionKey)
        defaults.removeObject(forKey: acceptedAtKey)
    }
}
