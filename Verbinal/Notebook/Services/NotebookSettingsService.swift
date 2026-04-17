// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

struct NotebookSettings: Codable, Equatable {
    var fontSize: Double = 12
    var wordWrap: Bool = true
    var autosaveEnabled: Bool = true
    var autosaveInterval: TimeInterval = 30
}

@Observable
final class NotebookSettingsService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "NotebookSettings")
    private(set) var settings: NotebookSettings

    init() {
        settings = Self.load()
    }

    func update(_ settings: NotebookSettings) {
        self.settings = settings
        save()
    }

    // MARK: - Persistence

    private static var fileURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal/Notebook", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private static func load() -> NotebookSettings {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return NotebookSettings()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(NotebookSettings.self, from: data)
        } catch {
            logger.warning("Failed to decode notebook settings, using defaults: \(error.localizedDescription, privacy: .public)")
            return NotebookSettings()
        }
    }

    private func save() {
        guard let url = Self.fileURL else { return }
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save notebook settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
