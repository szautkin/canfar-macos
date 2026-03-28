// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
