// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
