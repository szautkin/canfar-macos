// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct RecentLaunch: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var type: String = ""
    var image: String = ""
    var imageLabel: String = ""
    var project: String = ""
    var resourceType: String = "flexible"
    var cores: Int = 0
    var ram: Int = 0
    var gpus: Int = 0
    var launchedAt: Date = Date()
}
