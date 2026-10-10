// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// The launch form's defaults: what the person keeps, and whether the form shows them.
extension SessionLaunchModel {
    // MARK: - Default management

    /// Toggle whether the current project selection is saved as the user's default.
    func toggleDefaultProject() {
        guard let settingsService, !username.isEmpty, !selectedProject.isEmpty else { return }
        let current = settingsService.settings(for: username)?.defaultProject
        let next = (current == selectedProject) ? nil : selectedProject
        settingsService.setDefaultProject(next, for: username)
    }

    /// Toggle whether the current image selection is saved as the user's default.
    func toggleDefaultImage() {
        guard let settingsService, !username.isEmpty, let img = selectedImage else { return }
        let current = settingsService.settings(for: username)?.defaultContainerImageID
        let next = (current == img.id) ? nil : img.id
        settingsService.setDefaultImage(next, for: username)
    }

    /// Toggle whether the current session type is saved as the user's default.
    func toggleDefaultSessionType() {
        guard let settingsService, !username.isEmpty else { return }
        let current = settingsService.settings(for: username)?.defaultSessionType
        let next = (current == selectedType) ? nil : selectedType
        settingsService.setDefaultSessionType(next, for: username)
        recomputeDefaultFlags()
    }

    var isSelectedProjectDefault: Bool {
        guard let settingsService, !username.isEmpty, !selectedProject.isEmpty else { return false }
        return settingsService.settings(for: username)?.defaultProject == selectedProject
    }

    var isSelectedImageDefault: Bool {
        guard let settingsService, !username.isEmpty, let img = selectedImage else { return false }
        return settingsService.settings(for: username)?.defaultContainerImageID == img.id
    }

    func computeIsSelectedSessionTypeDefault() -> Bool {
        guard let settingsService, !username.isEmpty else { return false }
        return settingsService.settings(for: username)?.defaultSessionType == selectedType
    }

    /// True when the current resource selection matches the saved defaults.
    func computeIsSelectedResourcesDefault() -> Bool {
        guard let settingsService, !username.isEmpty,
              let saved = settingsService.settings(for: username),
              let savedType = saved.defaultResourceType else { return false }
        guard savedType == resourceType else { return false }
        if savedType == "flexible" { return true }
        return saved.defaultCores == cores
            && saved.defaultRam == ram
            && saved.defaultGpus == gpus
    }

    /// Recompute the cached default-match flags from the current form inputs
    /// and saved settings. Cheap (one settings lookup); called only at change
    /// points, never from a view body.
    func recomputeDefaultFlags() {
        isSelectedSessionTypeDefault = computeIsSelectedSessionTypeDefault()
        isSelectedResourcesDefault = computeIsSelectedResourcesDefault()
    }

    /// Save (or clear) the current resource selection as the user's default.
    func toggleDefaultResources() {
        guard let settingsService, !username.isEmpty else { return }
        if isSelectedResourcesDefault {
            settingsService.setDefaultResources(
                resourceType: nil, cores: nil, ram: nil, gpus: nil,
                for: username
            )
        } else {
            settingsService.setDefaultResources(
                resourceType: resourceType,
                cores: resourceType == "fixed" ? cores : nil,
                ram: resourceType == "fixed" ? ram : nil,
                gpus: resourceType == "fixed" ? gpus : nil,
                for: username
            )
        }
        recomputeDefaultFlags()
    }

    private static let cacheAgeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Relative description of when the image cache was last updated, e.g. "3h ago".
    var cacheAgeDescription: String? {
        guard let timestamp = cacheService?.cacheTimestamp else { return nil }
        return Self.cacheAgeFormatter.localizedString(for: timestamp, relativeTo: Date())
    }
}
