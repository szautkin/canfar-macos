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

final class PlatformService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    func getStats() async throws -> SkahaStatsResponse {
        let (data, _) = try await network.get(endpoints.statsURL, accept: "application/json")
        let decoder = JSONDecoder()

        // API may return a single object or an array-wrapped object
        if let stats = try? decoder.decode(SkahaStatsResponse.self, from: data) {
            return stats
        }
        if let array = try? decoder.decode([SkahaStatsResponse].self, from: data),
           let first = array.first {
            return first
        }
        // Fall back to strict decode so the caller gets a clear error
        return try decoder.decode(SkahaStatsResponse.self, from: data)
    }
}
