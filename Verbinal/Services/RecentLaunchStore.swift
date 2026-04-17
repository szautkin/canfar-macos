// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

@Observable
final class RecentLaunchStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "RecentLaunches")
    private let maxEntries = 10
    private let persistence = DiskPersistence<[RecentLaunch]>(
        subdirectory: "Verbinal",
        fileName: "recent_launches.json",
        logger: logger
    )
    private(set) var launches: [RecentLaunch] = []

    init() {
        launches = persistence.read() ?? []
    }

    func contains(name: String) -> Bool {
        launches.contains { $0.name == name }
    }

    func save(_ launch: RecentLaunch) {
        if let idx = launches.firstIndex(where: { $0.name == launch.name }) {
            launches.remove(at: idx)
        }
        var updated = launch
        updated.launchedAt = Date()
        launches.insert(updated, at: 0)
        if launches.count > maxEntries {
            launches = Array(launches.prefix(maxEntries))
        }
        persistence.write(launches)
    }

    func remove(_ launch: RecentLaunch) {
        launches.removeAll { $0.id == launch.id }
        persistence.write(launches)
    }

    func clear() {
        launches.removeAll()
        persistence.write(launches)
    }
}
