// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Observation

@Observable
final class RecentLaunchStore {
    private let maxEntries = 10
    private let fileName = "recent_launches.json"
    private(set) var launches: [RecentLaunch] = []

    init() {
        launches = readFromDisk()
    }

    func save(_ launch: RecentLaunch) {
        // If same session name exists, update and move to top
        if let idx = launches.firstIndex(where: { $0.name == launch.name }) {
            launches.remove(at: idx)
        }

        var updated = launch
        updated.launchedAt = Date()
        launches.insert(updated, at: 0)

        // Trim to max
        if launches.count > maxEntries {
            launches = Array(launches.prefix(maxEntries))
        }

        writeToDisk()
    }

    func remove(_ launch: RecentLaunch) {
        launches.removeAll { $0.id == launch.id }
        writeToDisk()
    }

    func clear() {
        launches.removeAll()
        writeToDisk()
    }

    // MARK: - Persistence

    private var fileURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = appSupport?.appendingPathComponent("Verbinal", isDirectory: true) else { return nil }

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        return dir.appendingPathComponent(fileName)
    }

    private func readFromDisk() -> [RecentLaunch] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecentLaunch].self, from: data)) ?? []
    }

    private func writeToDisk() {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(launches) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
