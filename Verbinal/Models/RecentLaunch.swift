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
