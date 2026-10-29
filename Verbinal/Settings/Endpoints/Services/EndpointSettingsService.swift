// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// MainActor-bound observable store for the user's endpoint overrides.
///
/// Overrides persist as one JSON blob in `UserDefaults` under the
/// `com.codebg.Verbinal.endpoints.overrides` key — no secrets live here,
/// so UserDefaults (not the Keychain) is the right home. Mutations land
/// on the published `overrides` only AFTER the write succeeds, matching
/// the `ImageDiscoverySettingsService` convention.
///
/// A change applies at once: `onChange` tells the app, which updates the
/// endpoints its services read on each request (plan 53 C5).
@MainActor
@Observable
final class EndpointSettingsService {

    private static let overridesKey = "com.codebg.Verbinal.endpoints.overrides"

    private let userDefaults: UserDefaults

    private(set) var overrides: EndpointOverrides

    /// Told when an override changed: the app applies it live.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    /// Where each endpoint changed is recorded (plan 23 C).
    private let changes: ChangeLog

    init(userDefaults: UserDefaults = .standard, changes: ChangeLog = .shared) {
        self.userDefaults = userDefaults
        self.changes = changes
        if let data = userDefaults.data(forKey: Self.overridesKey),
           let decoded = try? JSONDecoder().decode(EndpointOverrides.self, from: data) {
            self.overrides = decoded
        } else {
            self.overrides = EndpointOverrides()
        }
    }

    /// Set (or clear, when blank) one endpoint override. No-op writes
    /// don't touch persistence and change nothing.
    func setOverride(_ value: String, for field: EndpointField) {
        var updated = overrides
        guard updated.set(value, for: field) else { return }
        persist(updated)
        changes.done("change_setting", "the endpoint \(field.rawValue) to \(value.isEmpty ? "its default" : value)")
    }

    func clearOverride(for field: EndpointField) {
        var updated = overrides
        guard updated.set(nil, for: field) else { return }
        persist(updated)
        changes.done("change_setting", "the endpoint \(field.rawValue) to its default")
    }

    /// Drop every override. Exposed behind the destructive Reset button.
    func resetToDefaults() {
        guard !overrides.isEmpty else { return }
        persist(EndpointOverrides())
        changes.done("change_setting", "every endpoint to its default")
    }

    private func persist(_ updated: EndpointOverrides) {
        guard let data = try? JSONEncoder().encode(updated) else { return }
        userDefaults.set(data, forKey: Self.overridesKey)
        overrides = updated
        onChange?()
    }
}
