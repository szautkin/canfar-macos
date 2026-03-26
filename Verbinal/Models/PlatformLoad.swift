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

struct SkahaStatsResponse: Codable {
    let instances: InstanceStats?
    let cores: CoreStats?
    let ram: RamStats?
}

struct InstanceStats: Codable {
    let session: Int?
    let desktopApp: Int?
    let headless: Int?
    let total: Int?
}

// CPU core values may arrive as a number or a string from the API.
struct CoreStats: Codable {
    let requestedCPUCores: Double
    let cpuCoresAvailable: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedCPUCores = Self.flexibleDouble(from: container, forKey: .requestedCPUCores)
        cpuCoresAvailable = Self.flexibleDouble(from: container, forKey: .cpuCoresAvailable)
    }

    private static func flexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double {
        if let v = try? container.decode(Double.self, forKey: key) { return v }
        if let s = try? container.decode(String.self, forKey: key),
           let v = Double(s) { return v }
        return 0
    }

    enum CodingKeys: String, CodingKey {
        case requestedCPUCores, cpuCoresAvailable
    }
}

struct RamStats: Codable {
    let requestedRAM: String?
    let ramAvailable: String?
}
