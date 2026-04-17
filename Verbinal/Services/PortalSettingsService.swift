// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

// MARK: - Model

/// Per-user Portal preferences: which project/image/session-type to auto-select when
/// the user opens the Portal, plus optional resource defaults. Keyed by username so
/// shared machines do not leak defaults.
struct PortalSettings: Codable, Equatable {
    var username: String
    var defaultProject: String?
    var defaultContainerImageID: String?
    var defaultSessionType: String?
    /// Optional resource preset. When `resourceType == "fixed"` the `cores`, `ram`,
    /// and `gpus` values are applied. When nil or "flexible", the form stays on flexible.
    var defaultResourceType: String?
    var defaultCores: Int?
    var defaultRam: Int?
    var defaultGpus: Int?
    var modifiedAt: Date

    init(username: String,
         defaultProject: String? = nil,
         defaultContainerImageID: String? = nil,
         defaultSessionType: String? = nil,
         defaultResourceType: String? = nil,
         defaultCores: Int? = nil,
         defaultRam: Int? = nil,
         defaultGpus: Int? = nil,
         modifiedAt: Date = Date()) {
        self.username = username
        self.defaultProject = defaultProject
        self.defaultContainerImageID = defaultContainerImageID
        self.defaultSessionType = defaultSessionType
        self.defaultResourceType = defaultResourceType
        self.defaultCores = defaultCores
        self.defaultRam = defaultRam
        self.defaultGpus = defaultGpus
        self.modifiedAt = modifiedAt
    }

    var isEmpty: Bool {
        defaultProject == nil
            && defaultContainerImageID == nil
            && defaultSessionType == nil
            && defaultResourceType == nil
    }

    var hasResourceDefaults: Bool {
        defaultResourceType != nil
    }
}

// MARK: - Service

/// Persists per-user Portal defaults to `~/Library/Application Support/Verbinal/portal_settings.json`.
/// `@MainActor` isolated because SwiftUI views observe the `settingsByUser` dictionary —
/// all mutations must happen on main. Settings survive logout; only the image cache
/// is cleared on user change.
@Observable
@MainActor
final class PortalSettingsService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "PortalSettings")
    private let persistence: DiskPersistence<[String: PortalSettings]>
    private(set) var settingsByUser: [String: PortalSettings] = [:]

    init(fileName: String = "portal_settings.json") {
        self.persistence = DiskPersistence(
            subdirectory: "Verbinal",
            fileName: fileName,
            logger: Self.logger
        )
        self.settingsByUser = persistence.read() ?? [:]
    }

    func settings(for username: String) -> PortalSettings? {
        guard !username.isEmpty else { return nil }
        return settingsByUser[username]
    }

    func save(_ settings: PortalSettings) {
        guard !settings.username.isEmpty else { return }
        var updated = settings
        updated.modifiedAt = Date()
        settingsByUser[settings.username] = updated
        persistence.write(settingsByUser)
    }

    /// Load settings (creating default if absent), apply `transform`, then save.
    /// Callers: `update(for: user) { $0.defaultProject = "skaha" }`.
    /// Closes the service against future "new default field" additions.
    func update(for username: String, _ transform: (inout PortalSettings) -> Void) {
        guard !username.isEmpty else { return }
        var current = settingsByUser[username] ?? PortalSettings(username: username)
        transform(&current)
        save(current)
    }

    // MARK: - Convenience setters (delegate to `update`)

    func setDefaultProject(_ project: String?, for username: String) {
        update(for: username) { $0.defaultProject = project }
    }

    func setDefaultImage(_ imageID: String?, for username: String) {
        update(for: username) { $0.defaultContainerImageID = imageID }
    }

    func setDefaultSessionType(_ type: String?, for username: String) {
        update(for: username) { $0.defaultSessionType = type }
    }

    func setDefaultResources(
        resourceType: String?,
        cores: Int?,
        ram: Int?,
        gpus: Int?,
        for username: String
    ) {
        update(for: username) {
            $0.defaultResourceType = resourceType
            $0.defaultCores = cores
            $0.defaultRam = ram
            $0.defaultGpus = gpus
        }
    }

    func clearAll() {
        settingsByUser.removeAll()
        persistence.write(settingsByUser)
    }
}
